using Microsoft.Extensions.Logging;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;

namespace Remotely.Server.Services
{
    /// <summary>
    /// Active Directory login settings. Read from ad-config.env and ad-users.txt in the folder named by
    /// SECUREDESK_AD_DIR (default /ad). Nothing here is editable from the web console.
    /// </summary>
    public interface IAdSettings
    {
        bool Enabled { get; }
        /// <summary>Default true. Anything but an explicit "false" keeps 2FA required.</summary>
        bool RequireTwoFactor { get; }
        string Server { get; }
        int Port { get; }
        bool UseLdaps { get; }
        bool AllowInsecure { get; }
        string Domain { get; }
        string BaseDn { get; }
        string ServiceAccount { get; }
        string ServicePassword { get; }
        string UserAttribute { get; }
        string UserFilter { get; }
        string AdminsGroup { get; }
        string TechsGroup { get; }
        string CaCertFile { get; }
        int UserCount { get; }
        bool IsUserAllowed(string username);
        /// <summary>Empty list when the configuration can be used.</summary>
        IReadOnlyList<string> Validate();
    }

    public class AdSettings : IAdSettings
    {
        private readonly object _usersLock = new();
        private readonly string _usersPath;
        private HashSet<string> _users = new(StringComparer.OrdinalIgnoreCase);
        private DateTime _usersStamp = DateTime.MinValue;

        public AdSettings(ILogger<AdSettings> logger)
        {
            var dir = Environment.GetEnvironmentVariable("SECUREDESK_AD_DIR");
            if (string.IsNullOrWhiteSpace(dir))
            {
                dir = "/ad";
            }
            var configPath = Path.Combine(dir, "ad-config.env");
            _usersPath = Path.Combine(dir, "ad-users.txt");

            var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            var hash = "no-file";
            try
            {
                if (File.Exists(configPath))
                {
                    var bytes = File.ReadAllBytes(configPath);
                    hash = Convert.ToHexString(SHA256.HashData(bytes)).Substring(0, 12).ToLowerInvariant();
                    foreach (var raw in Encoding.UTF8.GetString(bytes).Split('\n'))
                    {
                        var line = raw.Trim().TrimStart('﻿');
                        if (line.Length == 0 || line.StartsWith("#"))
                        {
                            continue;
                        }
                        var eq = line.IndexOf('=');
                        if (eq <= 0)
                        {
                            continue;
                        }
                        var key = line.Substring(0, eq).Trim();
                        var val = line.Substring(eq + 1).Trim();
                        if (val.Length >= 2 && ((val[0] == '"' && val[val.Length - 1] == '"') || (val[0] == '\'' && val[val.Length - 1] == '\'')))
                        {
                            val = val.Substring(1, val.Length - 2);
                        }
                        values[key] = val;
                    }
                }
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Could not read the Active Directory configuration. AD login stays off.");
                values.Clear();
            }

            string Get(string key, string def = "") => values.TryGetValue(key, out var v) && v.Length > 0 ? v : def;
            bool GetBool(string key, bool def) => bool.TryParse(Get(key), out var b) ? b : def;

            Enabled = GetBool("AD_ENABLED", false);
            // Security setting: only an explicit "false" turns 2FA off. Missing, empty or garbage = required.
            RequireTwoFactor = !string.Equals(Get("AD_REQUIRE_2FA"), "false", StringComparison.OrdinalIgnoreCase);
            UseLdaps = GetBool("AD_USE_LDAPS", true);
            AllowInsecure = GetBool("AD_ALLOW_INSECURE", false);
            Server = Get("AD_SERVER");
            Port = int.TryParse(Get("AD_PORT"), out var p) && p > 0 && p < 65536 ? p : (UseLdaps ? 636 : 389);
            Domain = Get("AD_DOMAIN");
            BaseDn = Get("AD_BASE_DN");
            ServiceAccount = Get("AD_SERVICE_ACCOUNT");
            ServicePassword = Get("AD_SERVICE_PASSWORD");
            UserAttribute = Get("AD_USER_ATTRIBUTE", "sAMAccountName");
            UserFilter = Get("AD_USER_FILTER", "(&(objectCategory=person)(objectClass=user))");
            AdminsGroup = Get("AD_ADMINS_GROUP");
            TechsGroup = Get("AD_TECHS_GROUP");
            CaCertFile = Get("AD_CA_CERT_FILE");

            LoadUsers();
            logger.LogWarning("Active Directory login: enabled={Enabled}, require2FA={Require2fa}, allowed users={Users}, config={Hash}",
                Enabled, RequireTwoFactor, UserCount, hash);
            if (Enabled)
            {
                var problems = Validate();
                if (problems.Count > 0)
                {
                    logger.LogError("Active Directory login is ON but the configuration is incomplete: {Problems}", string.Join("; ", problems));
                }
            }
        }

        public bool Enabled { get; }
        public bool RequireTwoFactor { get; }
        public string Server { get; }
        public int Port { get; }
        public bool UseLdaps { get; }
        public bool AllowInsecure { get; }
        public string Domain { get; }
        public string BaseDn { get; }
        public string ServiceAccount { get; }
        public string ServicePassword { get; }
        public string UserAttribute { get; }
        public string UserFilter { get; }
        public string AdminsGroup { get; }
        public string TechsGroup { get; }
        public string CaCertFile { get; }

        public int UserCount
        {
            get
            {
                LoadUsers();
                lock (_usersLock)
                {
                    return _users.Count;
                }
            }
        }

        public bool IsUserAllowed(string username)
        {
            LoadUsers();
            lock (_usersLock)
            {
                return _users.Contains(username.Trim());
            }
        }

        public IReadOnlyList<string> Validate()
        {
            var problems = new List<string>();
            if (string.IsNullOrWhiteSpace(Server)) problems.Add("AD_SERVER is empty");
            if (string.IsNullOrWhiteSpace(BaseDn)) problems.Add("AD_BASE_DN is empty");
            if (string.IsNullOrWhiteSpace(ServiceAccount)) problems.Add("AD_SERVICE_ACCOUNT is empty");
            if (string.IsNullOrWhiteSpace(ServicePassword)) problems.Add("AD_SERVICE_PASSWORD is empty");
            if (!UseLdaps && !AllowInsecure) problems.Add("plain LDAP is refused (set AD_USE_LDAPS=true)");
            if (!string.IsNullOrWhiteSpace(CaCertFile) && !File.Exists(CaCertFile)) problems.Add("AD_CA_CERT_FILE not found");
            if (UserCount == 0) problems.Add("ad-users.txt has no users");
            return problems;
        }

        // ad-users.txt is re-read when the file changes, so adding a user needs no restart.
        private void LoadUsers()
        {
            try
            {
                var info = new FileInfo(_usersPath);
                var stamp = info.Exists ? info.LastWriteTimeUtc : DateTime.MinValue;
                lock (_usersLock)
                {
                    if (stamp == _usersStamp)
                    {
                        return;
                    }
                    var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                    if (info.Exists)
                    {
                        foreach (var raw in File.ReadAllLines(_usersPath))
                        {
                            var line = raw.Trim().TrimStart('﻿');
                            if (line.Length > 0 && !line.StartsWith("#"))
                            {
                                set.Add(line);
                            }
                        }
                    }
                    _users = set;
                    _usersStamp = stamp;
                }
            }
            catch
            {
                // keep the list from the last good read
            }
        }
    }
}
