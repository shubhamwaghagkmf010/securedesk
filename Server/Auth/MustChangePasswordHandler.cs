using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Identity;
using Remotely.Shared.Models;
using System.Threading.Tasks;

namespace Remotely.Server.Auth
{
    // Blocks any authenticated user whose CURRENT password still equals the well-known
    // default admin password (see docker/entrypoint.sh, README, Dockerfile LABEL) from
    // reaching anything except the password-change page. Checked dynamically on every
    // request against the live password hash - not just at account-creation time - so an
    // account that already existed before this feature shipped (e.g. a server that was
    // just upgraded to a newer image) is caught too, not only brand-new installs.
    // Re-opens on its own the moment the password actually changes (the hash no longer
    // matches) - nothing explicitly clears it.
    public class MustChangePasswordHandler : AuthorizationHandler<MustChangePasswordRequirement>
    {
        public const string DefaultAdminPassword = "SecureDesk@123";

        private readonly UserManager<RemotelyUser> _userManager;

        public MustChangePasswordHandler(UserManager<RemotelyUser> userManager)
        {
            _userManager = userManager;
        }

        protected override async Task HandleRequirementAsync(AuthorizationHandlerContext context, MustChangePasswordRequirement requirement)
        {
            if (context.User.Identity.IsAuthenticated)
            {
                var user = await _userManager.GetUserAsync(context.User);
                if (user is not null && await _userManager.CheckPasswordAsync(user, DefaultAdminPassword))
                {
                    context.Fail();
                    return;
                }
            }
            context.Succeed(requirement);
        }
    }
}
