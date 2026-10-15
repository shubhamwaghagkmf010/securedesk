namespace Remotely.Shared.Models
{
    /// <summary>
    /// Server URL that is built into the Windows installer and the Windows session client.
    /// Empty (default): the user types the server URL, exactly like upstream Remotely.
    /// Set by build\Build-WindowsClients.ps1 -ServerUrl https://your-server (the script restores this file afterwards).
    /// </summary>
    public static class EmbeddedServer
    {
        public const string Url = "";
    }
}
