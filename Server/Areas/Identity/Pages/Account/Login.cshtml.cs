using System;
using System.Collections.Generic;
using System.ComponentModel.DataAnnotations;
using System.Linq;
using System.Text.Encodings.Web;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.Identity.UI.Services;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using Microsoft.Extensions.Logging;
using Remotely.Shared.Models;
using Remotely.Server.Services;
using Microsoft.AspNetCore.WebUtilities;
using System.Text;
using System.Security.Claims;

namespace Remotely.Server.Areas.Identity.Pages.Account
{
    [AllowAnonymous]
    public class LoginModel : PageModel
    {
        private readonly UserManager<RemotelyUser> _userManager;
        private readonly SignInManager<RemotelyUser> _signInManager;
        private readonly ILogger<LoginModel> _logger;
        private readonly IDataService _dataService;
        private readonly IAdSettings _adSettings;
        private readonly ILdapAuthService _ldap;
        private readonly IAdUserService _adUsers;

        public LoginModel(SignInManager<RemotelyUser> signInManager, 
            UserManager<RemotelyUser> userManager,
            ILogger<LoginModel> logger,
            IDataService dataService,
            IAdSettings adSettings,
            ILdapAuthService ldap,
            IAdUserService adUsers)
        {
            _adSettings = adSettings;
            _ldap = ldap;
            _adUsers = adUsers;
            _userManager = userManager;
            _signInManager = signInManager;
            _logger = logger;
            _dataService = dataService;
        }

        [BindProperty]
        public InputModel Input { get; set; }

        public bool AdEnabled => _adSettings.Enabled;

        public IList<AuthenticationScheme> ExternalLogins { get; set; }

        public string ReturnUrl { get; set; }

        [TempData]
        public string ErrorMessage { get; set; }

        public class InputModel
        {
            [Required]
            [Display(Name = "Username or email")]
            public string Email { get; set; }

            [Required]
            [DataType(DataType.Password)]
            public string Password { get; set; }

            [Display(Name = "Remember me?")]
            public bool RememberMe { get; set; }
        }

        public async Task OnGetAsync(string returnUrl = null)
        {
            if (!string.IsNullOrEmpty(ErrorMessage))
            {
                ModelState.AddModelError(string.Empty, ErrorMessage);
            }

            returnUrl ??= Url.Content("~/");

            // Clear the existing external cookie to ensure a clean login process
            await HttpContext.SignOutAsync(IdentityConstants.ExternalScheme);

            ExternalLogins = (await _signInManager.GetExternalAuthenticationSchemesAsync()).ToList();

            ReturnUrl = returnUrl;
        }

        public async Task<IActionResult> OnPostAsync(string returnUrl = null)
        {
            returnUrl ??= Url.Content("~/");

            ExternalLogins = (await _signInManager.GetExternalAuthenticationSchemesAsync()).ToList();
        
            if (ModelState.IsValid)
            {
                var typed = Input.Email.Trim();
                var known = await _userManager.FindByNameAsync(typed);
                if (known == null && typed.Contains('@'))
                {
                    known = await _userManager.FindByEmailAsync(typed);
                }
                if (known != null && (await _userManager.GetClaimsAsync(known)).Any(x => x.Type == AdUserService.AdClaimType))
                {
                    // a directory user is only ever checked against Active Directory, never with a local password
                    if (!_adSettings.Enabled)
                    {
                        ModelState.AddModelError(string.Empty, "Invalid login attempt.");
                        return Page();
                    }
                    return await AdLoginAsync(StripDomain(typed.Contains('@') ? typed.Substring(0, typed.IndexOf('@')) : typed), returnUrl);
                }
                if (known == null && _adSettings.Enabled)
                {
                    // not a local account: check Active Directory
                    return await AdLoginAsync(StripDomain(typed), returnUrl);
                }

                // This doesn't count login failures towards account lockout
                // To enable password failures to trigger account lockout, set lockoutOnFailure: true
                var result = await _signInManager.PasswordSignInAsync(Input.Email, Input.Password, Input.RememberMe, lockoutOnFailure: false);
                if (result.Succeeded)
                {
                    _logger.LogInformation("User logged in.");
                    return LocalRedirect(returnUrl);
                }
                if (result.RequiresTwoFactor)
                {
                    return RedirectToPage("./LoginWith2fa", new { ReturnUrl = returnUrl, RememberMe = Input.RememberMe });
                }
                if (result.IsLockedOut)
                {
                    _logger.LogWarning("User account locked out.");
                    return RedirectToPage("./Lockout");
                }
                else
                {
                    if (await _dataService.TempPasswordSignIn(Input.Email, Input.Password))
                    {
                        var user = await _userManager.FindByNameAsync(Input.Email);
                        var code = await _userManager.GeneratePasswordResetTokenAsync(user);
                        code = WebEncoders.Base64UrlEncode(Encoding.UTF8.GetBytes(code));
                        var callbackUrl = Url.Page(
                            "/Account/ResetPassword",
                            pageHandler: null,
                            values: new { area = "Identity", code },
                            protocol: Request.Scheme);

                        return Redirect(callbackUrl);
                    }

                    ModelState.AddModelError(string.Empty, "Invalid login attempt.");
                    return Page();
                }
            }

            // If we got this far, something failed, redisplay form
            return Page();
        }

        private string StripDomain(string typed)
        {
            var suffix = "@" + _adSettings.Domain;
            return !string.IsNullOrWhiteSpace(_adSettings.Domain) && typed.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)
                ? typed.Substring(0, typed.Length - suffix.Length)
                : typed;
        }

        private async Task<IActionResult> AdLoginAsync(string username, string returnUrl)
        {
            var ad = await _ldap.AuthenticateAsync(username, Input.Password);
            if (ad.Kind == AdAuthKind.Locked)
            {
                ModelState.AddModelError(string.Empty, "Too many wrong attempts. Please wait a few minutes and try again.");
                return Page();
            }
            if (ad.Kind == AdAuthKind.Unavailable)
            {
                ModelState.AddModelError(string.Empty, "The company directory is not reachable right now. Please try again later or ask your administrator.");
                return Page();
            }
            if (ad.Kind != AdAuthKind.Success)
            {
                _logger.LogWarning("AD login failed for {User}: {Reason}", username, ad.Reason);
                ModelState.AddModelError(string.Empty, "Invalid login attempt.");
                return Page();
            }

            var user = await _adUsers.EnsureUserAsync(ad);
            if (user == null)
            {
                ModelState.AddModelError(string.Empty, "Invalid login attempt.");
                return Page();
            }
            if (await _userManager.IsLockedOutAsync(user))
            {
                return RedirectToPage("./Lockout");
            }

            if (await _userManager.GetTwoFactorEnabledAsync(user))
            {
                if (await _signInManager.IsTwoFactorClientRememberedAsync(user))
                {
                    await _signInManager.SignInAsync(user, Input.RememberMe, "ldap");
                    return LocalRedirect(returnUrl);
                }
                // the same second step that local accounts use: the code page finishes the sign in
                var identity = new ClaimsIdentity(IdentityConstants.TwoFactorUserIdScheme);
                identity.AddClaim(new Claim(ClaimTypes.Name, user.Id));
                await HttpContext.SignInAsync(IdentityConstants.TwoFactorUserIdScheme, new ClaimsPrincipal(identity));
                return RedirectToPage("./LoginWith2fa", new { ReturnUrl = returnUrl, RememberMe = Input.RememberMe });
            }

            if (_adSettings.RequireTwoFactor)
            {
                // first login: the only page that opens is the authenticator setup (see Startup)
                await _signInManager.SignInWithClaimsAsync(user, Input.RememberMe, new[] { new Claim("sd_2fa_setup", "1") });
                return LocalRedirect("/Identity/Account/Manage/EnableAuthenticator");
            }

            await _signInManager.SignInAsync(user, Input.RememberMe, "ldap");
            return LocalRedirect(returnUrl);
        }
    }
}
