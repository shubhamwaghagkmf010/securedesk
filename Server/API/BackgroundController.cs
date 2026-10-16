using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Remotely.Server.Services;
using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;

namespace Remotely.Server.API
{
    /// <summary>
    /// Stores the custom page background image chosen by a server administrator.
    /// The file lives in the persistent data folder (/remotely-data/branding in Docker).
    /// </summary>
    public static class BackgroundStorage
    {
        public const long MaxBytes = 6 * 1024 * 1024;

        public static string Dir
        {
            get
            {
                var root = Environment.GetEnvironmentVariable("SECUREDESK_DATA_DIR");
                if (string.IsNullOrWhiteSpace(root))
                {
                    root = Directory.Exists("/remotely-data")
                        ? "/remotely-data"
                        : Path.Combine(AppContext.BaseDirectory, "AppData");
                }
                return Path.Combine(root, "branding");
            }
        }

        public static string FindFile()
        {
            try
            {
                return Directory.Exists(Dir)
                    ? Directory.GetFiles(Dir, "background.*").FirstOrDefault()
                    : null;
            }
            catch
            {
                return null;
            }
        }

        /// <summary>0 when no custom background is set, otherwise a number that changes with every upload.</summary>
        public static long Version
        {
            get
            {
                var file = FindFile();
                return file is null ? 0 : File.GetLastWriteTimeUtc(file).Ticks;
            }
        }

        public static string DetectExtension(byte[] head)
        {
            if (head.Length >= 8 && head[0] == 0x89 && head[1] == 0x50 && head[2] == 0x4E && head[3] == 0x47)
            {
                return ".png";
            }
            if (head.Length >= 3 && head[0] == 0xFF && head[1] == 0xD8 && head[2] == 0xFF)
            {
                return ".jpg";
            }
            if (head.Length >= 12 && head[0] == 'R' && head[1] == 'I' && head[2] == 'F' && head[3] == 'F' &&
                head[8] == 'W' && head[9] == 'E' && head[10] == 'B' && head[11] == 'P')
            {
                return ".webp";
            }
            return null;
        }

        public static string ContentType(string path)
        {
            return Path.GetExtension(path).ToLowerInvariant() switch
            {
                ".png" => "image/png",
                ".jpg" => "image/jpeg",
                ".webp" => "image/webp",
                _ => "application/octet-stream"
            };
        }
    }

    [Route("branding/background")]
    [ApiController]
    public class BackgroundController : ControllerBase
    {
        private readonly IDataService _dataService;

        public BackgroundController(IDataService dataService)
        {
            _dataService = dataService;
        }

        [HttpGet]
        [AllowAnonymous]
        public IActionResult Get()
        {
            var file = BackgroundStorage.FindFile();
            if (file is null)
            {
                return Redirect("/images/sd_bg.png");
            }
            Response.Headers["Cache-Control"] = "no-cache";
            return PhysicalFile(file, BackgroundStorage.ContentType(file));
        }

        [HttpPost]
        [Authorize]
        [RequestSizeLimit(BackgroundStorage.MaxBytes + 1024 * 1024)]
        public async Task<IActionResult> Upload(IFormFile file)
        {
            var denied = CheckAdmin();
            if (denied is not null)
            {
                return denied;
            }

            if (file is null || file.Length == 0)
            {
                return BadRequest("Choose an image file.");
            }
            if (file.Length > BackgroundStorage.MaxBytes)
            {
                return BadRequest("The image is too large (max 6 MB).");
            }

            using var memory = new MemoryStream();
            await file.CopyToAsync(memory);
            var bytes = memory.ToArray();

            var extension = BackgroundStorage.DetectExtension(bytes);
            if (extension is null)
            {
                return BadRequest("Only PNG, JPG or WEBP images are allowed.");
            }

            Directory.CreateDirectory(BackgroundStorage.Dir);
            RemoveFiles();
            await System.IO.File.WriteAllBytesAsync(Path.Combine(BackgroundStorage.Dir, "background" + extension), bytes);
            return Ok();
        }

        [HttpDelete]
        [Authorize]
        public IActionResult Reset()
        {
            var denied = CheckAdmin();
            if (denied is not null)
            {
                return denied;
            }

            RemoveFiles();
            return Ok();
        }

        private IActionResult CheckAdmin()
        {
            // A custom header cannot be sent by a cross-site form, which blocks CSRF.
            if (Request.Headers["X-SD-Upload"] != "1")
            {
                return BadRequest();
            }

            var user = _dataService.GetUserByNameWithOrg(User?.Identity?.Name);
            if (user?.IsServerAdmin != true)
            {
                return StatusCode(StatusCodes.Status403Forbidden);
            }
            return null;
        }

        private static void RemoveFiles()
        {
            if (!Directory.Exists(BackgroundStorage.Dir))
            {
                return;
            }
            foreach (var old in Directory.GetFiles(BackgroundStorage.Dir, "background.*"))
            {
                System.IO.File.Delete(old);
            }
        }
    }
}
