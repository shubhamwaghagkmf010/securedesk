using Microsoft.AspNetCore.Identity;
using System.Collections.Generic;
using System.ComponentModel.DataAnnotations;
using System.Text.Json.Serialization;

namespace Remotely.Shared.Models
{
    public class RemotelyUser : IdentityUser
    {
        public ICollection<Alert> Alerts { get; set; }

        public List<DeviceGroup> DeviceGroups { get; set; }
        public bool IsAdministrator { get; set; }
        public bool IsServerAdmin { get; set; }

        [JsonIgnore]
        public Organization Organization { get; set; }

        public string OrganizationID { get; set; }

        public List<SavedScript> SavedScripts { get; set; }
        public List<ScriptSchedule> ScriptSchedules { get; set; }

        public string TempPassword { get; set; }

        // Set to this user's SecurityStamp at the moment they were created with the
        // well-known default admin password (see Register.cshtml.cs). Any password change
        // updates SecurityStamp automatically, so once it no longer matches, the account is
        // no longer treated as still using the default - no explicit "clear this flag"
        // step needed anywhere.
        public string SeededSecurityStamp { get; set; }

        public RemotelyUserOptions UserOptions { get; set; }
    }
}
