using Microsoft.Extensions.Logging;
using System;
using System.Security.Cryptography;
using System.Text;

namespace Remotely.Server.Services
{
    /// <summary>
    /// AES-256-GCM helper so the AD service account password can be stored as ciphertext in
    /// ad-config.env instead of plaintext. The decryption key lives only in the SECUREDESK_AD_KEY
    /// environment variable (set on the container, never written into the ./ad folder), so a leak
    /// of ad-config.env alone does not expose the password.
    /// Wire format: base64(nonce[12] + ciphertext + tag[16]).
    /// </summary>
    public static class AdCrypto
    {
        private const int NonceSize = 12;
        private const int TagSize = 16;

        public static string Encrypt(string plaintext, byte[] key)
        {
            var nonce = new byte[NonceSize];
            RandomNumberGenerator.Fill(nonce);
            var plainBytes = Encoding.UTF8.GetBytes(plaintext);
            var cipherBytes = new byte[plainBytes.Length];
            var tag = new byte[TagSize];

            using var aes = new AesGcm(key, TagSize);
            aes.Encrypt(nonce, plainBytes, cipherBytes, tag);

            var result = new byte[NonceSize + cipherBytes.Length + TagSize];
            Buffer.BlockCopy(nonce, 0, result, 0, NonceSize);
            Buffer.BlockCopy(cipherBytes, 0, result, NonceSize, cipherBytes.Length);
            Buffer.BlockCopy(tag, 0, result, NonceSize + cipherBytes.Length, TagSize);
            return Convert.ToBase64String(result);
        }

        public static string Decrypt(string base64, byte[] key)
        {
            var data = Convert.FromBase64String(base64);
            if (data.Length < NonceSize + TagSize)
            {
                throw new ArgumentException("AD_SERVICE_PASSWORD_ENC is too short to be valid.");
            }

            var nonce = new byte[NonceSize];
            var tag = new byte[TagSize];
            var cipherBytes = new byte[data.Length - NonceSize - TagSize];
            Buffer.BlockCopy(data, 0, nonce, 0, NonceSize);
            Buffer.BlockCopy(data, NonceSize, cipherBytes, 0, cipherBytes.Length);
            Buffer.BlockCopy(data, NonceSize + cipherBytes.Length, tag, 0, TagSize);

            var plainBytes = new byte[cipherBytes.Length];
            using var aes = new AesGcm(key, TagSize);
            aes.Decrypt(nonce, cipherBytes, tag, plainBytes);
            return Encoding.UTF8.GetString(plainBytes);
        }

        public static byte[] ParseKey(string base64Key)
        {
            byte[] key;
            try
            {
                key = Convert.FromBase64String(base64Key.Trim());
            }
            catch (FormatException)
            {
                throw new ArgumentException("SECUREDESK_AD_KEY is not valid base64.");
            }
            if (key.Length != 32)
            {
                throw new ArgumentException($"SECUREDESK_AD_KEY must decode to 32 bytes (AES-256); got {key.Length}.");
            }
            return key;
        }

        /// <summary>
        /// "Remotely_Server.dll --encrypt-ad-password": interactive one-shot tool. Reads the AD
        /// service account password from the console (masked, never echoed), generates a fresh
        /// AES-256 key, and prints the two lines to put in ad-config.env and in the container's
        /// environment respectively. Never logs or writes the plaintext password anywhere.
        /// </summary>
        public static int RunEncryptTool()
        {
            Console.WriteLine("This generates AD_SERVICE_PASSWORD_ENC (goes in ad-config.env) and");
            Console.WriteLine("SECUREDESK_AD_KEY (goes in the container's environment, NOT in ad-config.env).");
            Console.WriteLine("Keep SECUREDESK_AD_KEY somewhere separate from the ./ad folder (password manager, etc.).");
            Console.WriteLine();
            Console.Write("Enter the AD service account password (input hidden): ");
            var password = ReadMasked();
            Console.WriteLine();
            if (string.IsNullOrEmpty(password))
            {
                Console.WriteLine("FAIL: empty password, nothing generated.");
                return 1;
            }

            var key = new byte[32];
            RandomNumberGenerator.Fill(key);
            var cipher = Encrypt(password, key);

            Console.WriteLine();
            Console.WriteLine("Add this line to ad-config.env (replacing any AD_SERVICE_PASSWORD line):");
            Console.WriteLine($"AD_SERVICE_PASSWORD_ENC={cipher}");
            Console.WriteLine();
            Console.WriteLine("Set this as an environment variable on the container (e.g. in docker-compose.yml under");
            Console.WriteLine("'environment:', NOT inside the ./ad folder that gets mounted):");
            Console.WriteLine($"SECUREDESK_AD_KEY={Convert.ToBase64String(key)}");
            Console.WriteLine();
            Console.WriteLine("Done. The password you typed was never written to disk or logged.");
            return 0;
        }

        private static string ReadMasked()
        {
            // no real TTY attached (piped input, non-interactive docker run, CI, etc.):
            // ReadKey is unavailable, so fall back to a plain (unmasked) line read.
            if (Console.IsInputRedirected)
            {
                return Console.ReadLine() ?? "";
            }

            var sb = new StringBuilder();
            ConsoleKeyInfo key;
            while ((key = Console.ReadKey(intercept: true)).Key != ConsoleKey.Enter)
            {
                if (key.Key == ConsoleKey.Backspace)
                {
                    if (sb.Length > 0)
                    {
                        sb.Length--;
                    }
                    continue;
                }
                if (!char.IsControl(key.KeyChar))
                {
                    sb.Append(key.KeyChar);
                }
            }
            return sb.ToString();
        }
    }
}
