using Microsoft.AspNetCore.Identity;
using Microsoft.Extensions.Logging;
using Remotely.Shared.Models;
using System.Linq;
using System.Security.Claims;
using System.Threading.Tasks;

namespace Remotely.Server.Services
{
    public interface IAdUserService
    {
        /// <summary>Finds or creates the SecureDesk user for a person who passed the AD check. Null when it cannot be done.</summary>
        Task<RemotelyUser> EnsureUserAsync(AdAuthResult ad);
    }

    public class AdUserService : IAdUserService
    {
        /// <summary>Marks a user whose password lives in Active Directory. Such a user never signs in with a local password.</summary>
        public const string AdClaimType = "sd_ad_user";

        private readonly UserManager<RemotelyUser> _userManager;
        private readonly IDataService _dataService;
        private readonly IAdSettings _settings;
        private readonly ILogger<AdUserService> _logger;

        public AdUserService(UserManager<RemotelyUser> userManager, IDataService dataService, IAdSettings settings, ILogger<AdUserService> logger)
        {
            _userManager = userManager;
            _dataService = dataService;
            _settings = settings;
            _logger = logger;
        }

        public async Task<RemotelyUser> EnsureUserAsync(AdAuthResult ad)
        {
            var domain = string.IsNullOrWhiteSpace(_settings.Domain) ? "ad.local" : _settings.Domain.Trim();
            var userName = $"{ad.Username}@{domain}".ToLowerInvariant();
            var groupsDecideRole = !string.IsNullOrWhiteSpace(_settings.AdminsGroup) || !string.IsNullOrWhiteSpace(_settings.TechsGroup);

            var user = await _userManager.FindByNameAsync(userName);
            if (user != null)
            {
                var isDirectoryUser = (await _userManager.GetClaimsAsync(user)).Any(x => x.Type == AdClaimType);
                if (!isDirectoryUser && !string.IsNullOrEmpty(user.PasswordHash))
                {
                    // a local account with a password carries this name: never take it over through AD
                    _logger.LogError("AD login refused: {User} is a local account with a password.", userName);
                    return null;
                }
                if (!isDirectoryUser)
                {
                    await _userManager.AddClaimAsync(user, new Claim(AdClaimType, "1"));
                }
                else if (!string.IsNullOrEmpty(user.PasswordHash))
                {
                    // a directory user has no local password: remove one that should not be there
                    await _userManager.RemovePasswordAsync(user);
                    _logger.LogWarning("AD login: removed a local password from directory user {User}.", userName);
                }
                if (groupsDecideRole && user.IsAdministrator != ad.IsAdmin)
                {
                    user.IsAdministrator = ad.IsAdmin;
                    await _userManager.UpdateAsync(user);
                }
                return user;
            }

            // the organization marked as default, otherwise the one of the server administrator
            var orgId = (await _dataService.GetDefaultOrganization())?.ID
                ?? _userManager.Users.Where(x => x.IsServerAdmin).Select(x => x.OrganizationID).FirstOrDefault();
            if (string.IsNullOrEmpty(orgId))
            {
                _logger.LogError("AD login: there is no organization yet. Create the first administrator first.");
                return null;
            }

            user = new RemotelyUser
            {
                UserName = userName,
                Email = string.IsNullOrWhiteSpace(ad.Email) ? userName : ad.Email.Trim().ToLowerInvariant(),
                EmailConfirmed = true,
                OrganizationID = orgId,
                IsAdministrator = groupsDecideRole && ad.IsAdmin,
                UserOptions = new RemotelyUserOptions()
            };
            var result = await _userManager.CreateAsync(user);
            if (!result.Succeeded)
            {
                _logger.LogError("AD login: could not create {User}: {Errors}", userName, string.Join("; ", result.Errors.Select(x => x.Description)));
                return null;
            }
            await _userManager.AddClaimAsync(user, new Claim(AdClaimType, "1"));
            _logger.LogWarning("AD login: created SecureDesk user {User} (administrator: {Admin}).", userName, user.IsAdministrator);
            return user;
        }
    }
}
