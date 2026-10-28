using Microsoft.AspNetCore.Authorization;

namespace Remotely.Server.Auth
{
    public class MustChangePasswordRequirement : IAuthorizationRequirement
    {
        public const string PolicyName = "MustChangePassword";
    }
}
