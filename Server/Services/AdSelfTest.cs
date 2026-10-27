using Microsoft.Extensions.Logging.Abstractions;
using System;

namespace Remotely.Server.Services
{
    /// <summary>
    /// "Remotely_Server.dll --ad-test": used by apply-ad.sh. Checks the AD settings and the service account
    /// with the same code the login uses. Never prints a password. Exit code 0 = fine, 1 = problem.
    /// </summary>
    public static class AdSelfTest
    {
        public static int Run()
        {
            var settings = new AdSettings(NullLogger<AdSettings>.Instance);
            var service = new LdapAuthService(settings, NullLogger<LdapAuthService>.Instance);

            Console.WriteLine($"AD_ENABLED={settings.Enabled}  AD_REQUIRE_2FA={settings.RequireTwoFactor}  AD_BIND_MODE={settings.BindMode}  user list={(settings.UseAllowList ? settings.UserCount + " user(s)" : "off, groups decide")}");

            var problems = settings.Validate();
            if (problems.Count > 0)
            {
                foreach (var p in problems)
                {
                    Console.WriteLine("FAIL: " + p);
                }
                return 1;
            }

            var (ok, message) = service.TestAsync().GetAwaiter().GetResult();
            Console.WriteLine((ok ? "OK: " : "FAIL: ") + message);
            if (!ok)
            {
                return 1;
            }

            // optional: AD_TEST_USER / AD_TEST_PASSWORD are read from the environment of this one command only
            var user = Environment.GetEnvironmentVariable("AD_TEST_USER");
            var pass = Environment.GetEnvironmentVariable("AD_TEST_PASSWORD");
            if (!string.IsNullOrEmpty(user) && !string.IsNullOrEmpty(pass))
            {
                var r = service.CheckUserForTestAsync(user, pass).GetAwaiter().GetResult();
                Console.WriteLine($"Test login of '{user}': {r.Kind}" + (r.Kind == AdAuthKind.Success ? $" (administrator group: {r.IsAdmin})" : " - " + r.Reason));
                if (r.Kind != AdAuthKind.Success)
                {
                    return 1;
                }
            }
            return 0;
        }
    }
}
