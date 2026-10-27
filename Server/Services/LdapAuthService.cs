using Microsoft.Extensions.Logging;
using Novell.Directory.Ldap;
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace Remotely.Server.Services
{
    public enum AdAuthKind
    {
        Success,
        /// <summary>Not allowed, wrong password, unknown user, or too many attempts.</summary>
        Denied,
        Locked,
        /// <summary>The domain controller could not be reached or the service account was refused.</summary>
        Unavailable
    }

    public class AdAuthResult
    {
        public AdAuthKind Kind { get; set; }
        public string Username { get; set; }
        public string Email { get; set; }
        public string DisplayName { get; set; }
        public bool IsAdmin { get; set; }
        /// <summary>Only for the server log, never shown to the person who is logging in.</summary>
        public string Reason { get; set; }
    }

    public interface ILdapAuthService
    {
        Task<AdAuthResult> AuthenticateAsync(string username, string password);
        /// <summary>Checks the service account bind and a search under the base DN. Never prints a password.</summary>
        Task<(bool Ok, string Message)> TestAsync();
        /// <summary>Normal login check for one user, used by the self test.</summary>
        Task<AdAuthResult> CheckUserForTestAsync(string username, string password);
    }

    public class LdapAuthService : ILdapAuthService
    {
        private const int MaxFailures = 5;
        private static readonly TimeSpan LockTime = TimeSpan.FromMinutes(5);
        private static readonly Regex UsernameRegex = new(@"^[A-Za-z0-9._-]{1,64}$", RegexOptions.Compiled);
        private static readonly ConcurrentDictionary<string, (int Fails, DateTime LockedUntil)> Failures = new();

        private readonly IAdSettings _settings;
        private readonly ILogger<LdapAuthService> _logger;

        public LdapAuthService(IAdSettings settings, ILogger<LdapAuthService> logger)
        {
            _settings = settings;
            _logger = logger;
        }

        public async Task<AdAuthResult> AuthenticateAsync(string username, string password)
        {
            username = (username ?? string.Empty).Trim();
            if (!_settings.Enabled)
            {
                return Denied("AD login is off");
            }
            if (!UsernameRegex.IsMatch(username) || string.IsNullOrEmpty(password))
            {
                return Denied("bad user name or empty password");
            }
            if (!_settings.IsUserAllowed(username))
            {
                _logger.LogWarning("AD login refused: {User} is not in ad-users.txt.", username);
                RegisterFailure(username);
                return Denied("not in ad-users.txt");
            }
            var key = username.ToLowerInvariant();
            if (Failures.TryGetValue(key, out var f) && f.LockedUntil > DateTime.UtcNow)
            {
                _logger.LogWarning("AD login refused: {User} is locked for a few minutes after too many wrong passwords.", username);
                return new AdAuthResult { Kind = AdAuthKind.Locked, Reason = "locked" };
            }
            if (_settings.Validate().Count > 0)
            {
                return new AdAuthResult { Kind = AdAuthKind.Unavailable, Reason = "AD configuration is incomplete" };
            }

            var result = await Task.Run(() => Check(username, password));
            if (result.Kind == AdAuthKind.Success)
            {
                Failures.TryRemove(key, out _);
            }
            else if (result.Kind == AdAuthKind.Denied)
            {
                RegisterFailure(username);
            }
            return result;
        }

        public Task<AdAuthResult> CheckUserForTestAsync(string username, string password)
        {
            return Task.Run(() => Check(username, password));
        }

        public Task<(bool Ok, string Message)> TestAsync()
        {
            return Task.Run(() =>
            {
                var problems = _settings.Validate();
                if (problems.Count > 0)
                {
                    return (false, "Configuration incomplete: " + string.Join("; ", problems));
                }
                try
                {
                    using var conn = Connect();
                    if (_settings.UserBindMode)
                    {
                        return (true, $"Connected to {_settings.Server}:{_settings.Port}. No service account is used: each person signs in with their own password (test one real user with --test-login).");
                    }
                    conn.Bind(_settings.ServiceAccount, _settings.ServicePassword);
                    var cons = new LdapSearchConstraints { ReferralFollowing = false, MaxResults = 1, TimeLimit = 10000 };
                    var res = conn.Search(_settings.BaseDn, LdapConnection.ScopeBase, "(objectClass=*)", new[] { "1.1" }, false, cons);
                    if (!res.HasMore())
                    {
                        return (false, "Base DN returned nothing: " + _settings.BaseDn);
                    }
                    res.Next();
                    return (true, "Service account can sign in and the base DN is readable.");
                }
                catch (Exception ex)
                {
                    return (false, Describe(ex));
                }
            });
        }

        private AdAuthResult Check(string username, string password)
        {
            try
            {
                return _settings.UserBindMode ? CheckAsUser(username, password) : CheckWithServiceAccount(username, password);
            }
            catch (Exception ex)
            {
                _logger.LogError("AD login: {Message}", Describe(ex));
                return new AdAuthResult { Kind = AdAuthKind.Unavailable, Reason = Describe(ex) };
            }
        }

        // "user" mode: no service account. Only the password of the person who logs in is used. The name sent to the directory
        // is built from the typed user name (default user@suffix) and the entry that is read back is that same account.
        private AdAuthResult CheckAsUser(string username, string password)
        {
            using var conn = Connect();
            var bindName = _settings.UserBindFormat
                .Replace("{user}", username)
                .Replace("{suffix}", _settings.UpnSuffix ?? string.Empty);
            try
            {
                conn.Bind(bindName, password);
            }
            catch (LdapException ex) when (ex.ResultCode == LdapException.InvalidCredentials)
            {
                return Denied("wrong password, unknown user, or account locked/disabled in AD");
            }

            string searchBase;
            int scope;
            string filter;
            if (bindName.Contains('='))
            {
                // a full DN template (advanced / other directories): the entry that carries the typed name
                searchBase = _settings.BaseDn; scope = LdapConnection.ScopeSub;
                filter = $"(&{_settings.UserFilter}({_settings.UserAttribute}={EscapeFilter(username)}))";
            }
            else
            {
                // user@suffix: the entry whose userPrincipalName is exactly the name that just signed in
                searchBase = _settings.BaseDn; scope = LdapConnection.ScopeSub;
                filter = $"(&{_settings.UserFilter}(userPrincipalName={EscapeFilter(bindName)}))";
            }
            var attrs = new[] { "mail", "displayName", "memberOf", "userAccountControl" };
            var cons = new LdapSearchConstraints { ReferralFollowing = false, MaxResults = 2, TimeLimit = 10000 };
            var res = conn.Search(searchBase, scope, filter, attrs, false, cons);
            LdapEntry entry = null;
            var count = 0;
            while (res.HasMore())
            {
                try
                {
                    entry = res.Next();
                    count++;
                }
                catch (LdapReferralException)
                {
                }
            }
            if (count != 1)
            {
                _logger.LogWarning("AD login refused: {Count} entries found for {User} after sign-in.", count, username);
                return Denied("signed-in account could not be read back uniquely");
            }
            return Finish(entry, username);
        }

        private AdAuthResult CheckWithServiceAccount(string username, string password)
        {
            {
                using var conn = Connect();
                conn.Bind(_settings.ServiceAccount, _settings.ServicePassword);

                var filter = $"(&{_settings.UserFilter}({_settings.UserAttribute}={EscapeFilter(username)}))";
                var attrs = new[] { "mail", "displayName", "memberOf", "userAccountControl", _settings.UserAttribute };
                var cons = new LdapSearchConstraints { ReferralFollowing = false, MaxResults = 2, TimeLimit = 10000 };
                var res = conn.Search(_settings.BaseDn, LdapConnection.ScopeSub, filter, attrs, false, cons);

                LdapEntry entry = null;
                var count = 0;
                while (res.HasMore())
                {
                    try
                    {
                        entry = res.Next();
                        count++;
                    }
                    catch (LdapReferralException)
                    {
                    }
                }
                if (count != 1)
                {
                    _logger.LogWarning("AD login refused: {Count} entries found for {User}.", count, username);
                    return Denied(count == 0 ? "user not found in AD" : "user name is not unique in AD");
                }

                var uac = Attr(entry, "userAccountControl")?.StringValue;
                if (int.TryParse(uac, out var flags) && (flags & 2) != 0)
                {
                    return Denied("account is disabled in AD");
                }

                // the group is checked BEFORE the password is tried, so people outside the groups never produce
                // a failed sign-in in Active Directory (no lock-outs of accounts that cannot use SecureDesk anyway)
                var denied = CheckGroups(entry, username, out var inAdmins);
                if (denied != null)
                {
                    return denied;
                }

                // proves the password: bind as the user (an empty password would be an anonymous bind, refused above)
                try
                {
                    conn.Bind(entry.Dn, password);
                }
                catch (LdapException ex) when (ex.ResultCode == LdapException.InvalidCredentials)
                {
                    return Denied("wrong password");
                }

                return Success(entry, username, inAdmins);
            }
        }

        private AdAuthResult Finish(LdapEntry entry, string username)
        {
            var uac = Attr(entry, "userAccountControl")?.StringValue;
            if (int.TryParse(uac, out var flags) && (flags & 2) != 0)
            {
                return Denied("account is disabled in AD");
            }
            var denied = CheckGroups(entry, username, out var inAdmins);
            return denied ?? Success(entry, username, inAdmins);
        }

        private AdAuthResult CheckGroups(LdapEntry entry, string username, out bool inAdmins)
        {
            var groups = Attr(entry, "memberOf")?.StringValueArray ?? Array.Empty<string>();
            inAdmins = InGroup(groups, _settings.AdminsGroup);
            var inTechs = InGroup(groups, _settings.TechsGroup);
            if ((!string.IsNullOrWhiteSpace(_settings.AdminsGroup) || !string.IsNullOrWhiteSpace(_settings.TechsGroup)) && !inAdmins && !inTechs)
            {
                _logger.LogWarning("AD login refused: {User} is in neither the admins nor the technicians group.", username);
                return Denied("not in the configured AD group");
            }
            return null;
        }

        private static AdAuthResult Success(LdapEntry entry, string username, bool inAdmins) => new()
        {
            Kind = AdAuthKind.Success,
            Username = username,
            Email = Attr(entry, "mail")?.StringValue,
            DisplayName = Attr(entry, "displayName")?.StringValue,
            IsAdmin = inAdmins
        };

        // the library throws when an attribute is missing (for example a user without a mail address)
        private static LdapAttribute Attr(LdapEntry entry, string name)
        {
            try
            {
                return entry.GetAttribute(name);
            }
            catch (KeyNotFoundException)
            {
                return null;
            }
        }

        private LdapConnection Connect()
        {
            // Non-obsolete replacement for the old SecureSocketLayer + UserDefinedServerCertValidationDelegate API:
            // SSL and the cert-validation callback are configured on LdapConnectionOptions up front, before the
            // connection object is built, instead of being set on the LdapConnection afterwards.
            var options = new LdapConnectionOptions();
            if (_settings.UseLdaps)
            {
                options.UseSsl().ConfigureRemoteCertificateValidationCallback(ValidateServerCertificate);
            }
            var conn = new LdapConnection(options) { ConnectionTimeout = 8000 };
            conn.Connect(_settings.Server, _settings.Port);
            return conn;
        }

        private bool ValidateServerCertificate(object sender, X509Certificate certificate, X509Chain chain, SslPolicyErrors errors)
        {
            if (errors == SslPolicyErrors.None)
            {
                return true;
            }
            if (string.IsNullOrWhiteSpace(_settings.CaCertFile) || !File.Exists(_settings.CaCertFile) || certificate == null)
            {
                return false;
            }
            // the host name must still match; only the issuer is checked against the company CA file
            if ((errors & SslPolicyErrors.RemoteCertificateNameMismatch) != 0)
            {
                return false;
            }
            try
            {
                using var custom = new X509Chain();
                custom.ChainPolicy.TrustMode = X509ChainTrustMode.CustomRootTrust;
                custom.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
                custom.ChainPolicy.CustomTrustStore.Add(new X509Certificate2(_settings.CaCertFile));
                return custom.Build(new X509Certificate2(certificate));
            }
            catch
            {
                return false;
            }
        }

        private static bool InGroup(IEnumerable<string> memberOf, string group)
        {
            if (string.IsNullOrWhiteSpace(group))
            {
                return false;
            }
            group = group.Trim();
            foreach (var dn in memberOf)
            {
                if (group.Contains('='))
                {
                    if (string.Equals(dn.Trim(), group, StringComparison.OrdinalIgnoreCase))
                    {
                        return true;
                    }
                }
                else
                {
                    // the first part of the DN is the group name (CN=Name,... in Active Directory)
                    var m = Regex.Match(dn, @"^[A-Za-z]+=((?:\\.|[^,\\])*)");
                    if (m.Success && string.Equals(m.Groups[1].Value.Replace("\\,", ","), group, StringComparison.OrdinalIgnoreCase))
                    {
                        return true;
                    }
                }
            }
            return false;
        }

        private static string EscapeFilter(string value)
        {
            var sb = new StringBuilder();
            foreach (var c in value)
            {
                switch (c)
                {
                    case '\\': sb.Append("\\5c"); break;
                    case '*': sb.Append("\\2a"); break;
                    case '(': sb.Append("\\28"); break;
                    case ')': sb.Append("\\29"); break;
                    case '\0': sb.Append("\\00"); break;
                    default: sb.Append(c); break;
                }
            }
            return sb.ToString();
        }

        private static string Describe(Exception ex)
        {
            if (ex is LdapException le)
            {
                return $"LDAP error {le.ResultCode}: {le.LdapErrorMessage ?? le.Message}";
            }
            return ex.GetType().Name + ": " + ex.Message;
        }

        private static void RegisterFailure(string username)
        {
            if (Failures.Count > 20000)
            {
                Failures.Clear();
            }
            var key = username.ToLowerInvariant();
            Failures.AddOrUpdate(key,
                _ => (1, DateTime.MinValue),
                (_, old) =>
                {
                    if (old.LockedUntil > DateTime.UtcNow)
                    {
                        return old;
                    }
                    var fails = old.LockedUntil != DateTime.MinValue && old.LockedUntil <= DateTime.UtcNow ? 1 : old.Fails + 1;
                    return fails >= MaxFailures ? (0, DateTime.UtcNow + LockTime) : (fails, DateTime.MinValue);
                });
        }

        private static AdAuthResult Denied(string reason) => new() { Kind = AdAuthKind.Denied, Reason = reason };
    }
}
