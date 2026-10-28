using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Identity;
using Remotely.Shared.Models;
using System.Threading.Tasks;

namespace Remotely.Server.Auth
{
    // Blocks a user who is still on the well-known default admin password (see
    // Register.cshtml.cs, which only sets SeededSecurityStamp in that exact case) from
    // reaching anything except the password-change page. Changing the password updates
    // SecurityStamp automatically, so this re-opens on its own - nothing explicitly clears it.
    public class MustChangePasswordHandler : AuthorizationHandler<MustChangePasswordRequirement>
    {
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
                if (user is not null &&
                    !string.IsNullOrEmpty(user.SeededSecurityStamp) &&
                    user.SeededSecurityStamp == user.SecurityStamp)
                {
                    context.Fail();
                    return;
                }
            }
            context.Succeed(requirement);
        }
    }
}
