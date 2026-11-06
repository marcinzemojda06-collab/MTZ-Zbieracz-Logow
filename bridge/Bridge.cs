// Copyright (c) 2026 MTZ-belarus contributors
// SPDX-License-Identifier: MIT
// Compatible with C# 5 / .NET Framework 4.5 (Windows PowerShell 5.1 Add-Type).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace Mtz
{
    /// <summary>
    /// Publishes one explicitly selected diagnostic ZIP to a local browser extension.
    /// This is not an Internet uploader, a file server, or a command execution service.
    /// </summary>
    public sealed class LogBridge : IDisposable
    {
        public const int Port = 17643;
        public const int MaximumBundleBytes = 30 * 1024 * 1024;
        private const int MaximumHeaderBytes = 8192;
        private const int SocketTimeoutMilliseconds = 5000;
        private readonly object gate = new object();
        private readonly object lifecycleGate = new object();
        private TcpListener listener;
        private TcpClient activeClient;
        private Thread worker;
        private volatile bool stopping;
        private volatile bool disposed;
        private byte[] bundle;
        private byte[] token;
        private string fileName;
        private DateTime expiresUtc;
        private int downloadCount;
        private long publicationVersion;
        private string lastError = String.Empty;

        public int DownloadCount { get { return Interlocked.CompareExchange(ref downloadCount, 0, 0); } }

        public string LastError
        {
            get { lock (gate) { return lastError; } }
        }

        public bool HasPublishedPackage
        {
            get
            {
                lock (gate)
                {
                    return listener != null && !stopping && bundle != null && token != null && DateTime.UtcNow < expiresUtc;
                }
            }
        }

        public bool IsRunning
        {
            get { lock (gate) { return listener != null && !stopping; } }
        }

        /// <summary>Bind IPv4 loopback only. Throws if another program owns port 17643.</summary>
        public void Start()
        {
            lock (lifecycleGate)
            {
                ThrowIfDisposed();
                lock (gate)
                {
                    if (listener != null && !stopping) return;
                }

                TcpListener newListener = new TcpListener(IPAddress.Loopback, Port);
                newListener.ExclusiveAddressUse = true;
                try { newListener.Start(4); }
                catch (SocketException)
                {
                    newListener.Stop();
                    SetError("Nie można uruchomić lokalnego połączenia: port 17643 jest niedostępny.");
                    throw new InvalidOperationException(LastError);
                }

                lock (gate)
                {
                    stopping = false;
                    listener = newListener;
                    lastError = String.Empty;
                    worker = new Thread(delegate() { Serve(newListener); });
                    worker.IsBackground = true;
                    worker.Name = "MTZ local diagnostic handoff";
                    worker.Start();
                }
            }
        }

        /// <summary>
        /// Read an existing regular ZIP into a bounded immutable snapshot, replace the
        /// previous publication, and return a fresh 64-character lowercase hex token.
        /// The publication expires after 15 minutes. The path is never accepted over HTTP.
        /// </summary>
        public string Publish(string zipPath)
        {
            ThrowIfDisposed();
            if (String.IsNullOrWhiteSpace(zipPath)) throw new ArgumentException("Brak pliku ZIP.", "zipPath");
            string fullPath = Path.GetFullPath(zipPath);
            if (!String.Equals(Path.GetExtension(fullPath), ".zip", StringComparison.OrdinalIgnoreCase))
                throw new ArgumentException("Można przekazać wyłącznie paczkę ZIP.", "zipPath");

            FileAttributes attributes = File.GetAttributes(fullPath);
            if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
                throw new ArgumentException("Paczka musi być zwykłym plikiem ZIP.", "zipPath");

            byte[] snapshot;
            using (FileStream input = new FileStream(fullPath, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                long length = input.Length;
                if (length < 4 || length > MaximumBundleBytes)
                    throw new ArgumentException("Rozmiar paczki ZIP musi wynosić od 4 bajtów do 30 MiB.", "zipPath");
                snapshot = new byte[(int)length];
                int offset = 0;
                while (offset < snapshot.Length)
                {
                    int count = input.Read(snapshot, offset, snapshot.Length - offset);
                    if (count == 0) throw new IOException("Paczka ZIP zmieniła się podczas odczytu.");
                    offset += count;
                }
                if (input.ReadByte() != -1) throw new IOException("Paczka ZIP zmieniła się podczas odczytu.");
            }
            // ZIP local-file header or the end-of-central-directory record of an empty ZIP.
            bool zipMagic = snapshot[0] == 0x50 && snapshot[1] == 0x4b &&
                ((snapshot[2] == 0x03 && snapshot[3] == 0x04) ||
                 (snapshot[2] == 0x05 && snapshot[3] == 0x06));
            if (!zipMagic) throw new ArgumentException("Plik nie ma nagłówka ZIP.", "zipPath");

            string safeName = Regex.Replace(Path.GetFileName(fullPath), "[^A-Za-z0-9._-]", "_");
            safeName = Regex.Replace(safeName, "\\.{2,}", "_");
            if (safeName.Length > 0 && !Char.IsLetterOrDigit(safeName[0])) safeName = "MTZ-" + safeName;
            if (safeName.Length > 124) safeName = safeName.Substring(0, 120).TrimEnd('.') + ".zip";
            if (safeName.Length < 5) safeName = "MTZ-logi.zip";

            byte[] newToken = new byte[32];
            using (RandomNumberGenerator rng = RandomNumberGenerator.Create()) { rng.GetBytes(newToken); }
            StringBuilder hex = new StringBuilder(64);
            for (int i = 0; i < newToken.Length; i++) hex.Append(newToken[i].ToString("x2", CultureInfo.InvariantCulture));

            lock (gate)
            {
                ThrowIfDisposed();
                if (listener == null || stopping)
                {
                    Array.Clear(newToken, 0, newToken.Length);
                    throw new InvalidOperationException("Najpierw uruchom lokalne połączenie.");
                }
                if (token != null) Array.Clear(token, 0, token.Length);
                token = newToken;
                bundle = snapshot;
                fileName = safeName;
                expiresUtc = DateTime.UtcNow.AddMinutes(15);
                publicationVersion++;
                Interlocked.Exchange(ref downloadCount, 0);
                lastError = String.Empty;
            }
            return hex.ToString();
        }

        /// <summary>Revoke the current token and discard the in-memory publication.</summary>
        public void Revoke()
        {
            lock (gate)
            {
                if (token != null) Array.Clear(token, 0, token.Length);
                token = null;
                bundle = null;
                fileName = null;
                expiresUtc = DateTime.MinValue;
                publicationVersion++;
                Interlocked.Exchange(ref downloadCount, 0);
            }
        }

        public void Stop()
        {
            lock (lifecycleGate)
            {
                TcpListener oldListener;
                TcpClient oldClient;
                Thread oldWorker;
                lock (gate)
                {
                    stopping = true;
                    oldListener = listener;
                    oldClient = activeClient;
                    oldWorker = worker;
                    listener = null;
                    activeClient = null;
                    worker = null;
                }
                Revoke();
                if (oldClient != null) { try { oldClient.Close(); } catch (SocketException) { } }
                if (oldListener != null) oldListener.Stop();
                if (oldWorker != null && oldWorker != Thread.CurrentThread) oldWorker.Join(6000);
            }
        }

        public void Dispose()
        {
            lock (lifecycleGate)
            {
                if (disposed) return;
                Stop();
                disposed = true;
            }
        }

        private void Serve(TcpListener ownedListener)
        {
            try
            {
                while (!stopping && IsCurrentListener(ownedListener))
                {
                    TcpClient client = ownedListener.AcceptTcpClient();
                    lock (gate)
                    {
                        if (stopping) { client.Close(); break; }
                        activeClient = client;
                    }
                    try
                    {
                        client.NoDelay = true;
                        client.ReceiveTimeout = SocketTimeoutMilliseconds;
                        client.SendTimeout = SocketTimeoutMilliseconds;
                        Handle(client);
                    }
                    catch (IOException) { /* Disconnected or timed out. No request data is logged. */ }
                    catch (SocketException) { /* A local client may close the connection at any time. */ }
                    catch (ObjectDisposedException) { /* Stop() closes an active socket. */ }
                    finally
                    {
                        client.Close();
                        lock (gate) { if (Object.ReferenceEquals(activeClient, client)) activeClient = null; }
                    }
                }
            }
            catch (SocketException)
            {
                if (!stopping) SetError("Lokalne połączenie zostało przerwane. Uruchom program ponownie.");
            }
            catch (ObjectDisposedException)
            {
                if (!stopping) SetError("Lokalne połączenie zostało zamknięte. Uruchom program ponownie.");
            }
            finally
            {
                ownedListener.Stop();
                lock (gate)
                {
                    if (Object.ReferenceEquals(listener, ownedListener)) listener = null;
                }
            }
        }

        private void Handle(TcpClient client)
        {
            NetworkStream stream = client.GetStream();
            stream.ReadTimeout = SocketTimeoutMilliseconds;
            stream.WriteTimeout = SocketTimeoutMilliseconds;
            byte[] header = new byte[MaximumHeaderBytes];
            int used = 0;
            bool complete = false;
            Stopwatch requestClock = Stopwatch.StartNew();
            while (used < header.Length)
            {
                int remainingMilliseconds = SocketTimeoutMilliseconds - (int)requestClock.ElapsedMilliseconds;
                if (remainingMilliseconds <= 0) return;
                stream.ReadTimeout = remainingMilliseconds;
                int b = stream.ReadByte();
                if (b < 0) return;
                // Reject non-ASCII and all control characters other than CR/LF/HTAB.
                if (b > 126 || (b < 32 && b != 13 && b != 10 && b != 9))
                { WriteError(stream, 400, "Bad Request"); return; }
                header[used++] = (byte)b;
                if (used >= 4 && header[used - 4] == 13 && header[used - 3] == 10 &&
                    header[used - 2] == 13 && header[used - 1] == 10)
                { complete = true; break; }
            }
            if (!complete) { WriteError(stream, 431, "Request Header Fields Too Large"); return; }

            string text = Encoding.ASCII.GetString(header, 0, used);
            string[] lines = text.Split(new string[] { "\r\n" }, StringSplitOptions.None);
            if (lines.Length < 3) { WriteError(stream, 400, "Bad Request"); return; }
            string[] request = lines[0].Split(' ');
            if (request.Length != 3 || request[2] != "HTTP/1.1")
            { WriteError(stream, 400, "Bad Request"); return; }
            if (request[0] != "GET") { WriteError(stream, 405, "Method Not Allowed"); return; }
            if (request[1] != "/v1/bundle") { WriteError(stream, 404, "Not Found"); return; }

            Dictionary<string, string> headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            for (int i = 1; i < lines.Length - 2; i++)
            {
                string line = lines[i];
                int colon = line.IndexOf(':');
                if (colon <= 0 || line[0] == ' ' || line[0] == '\t' ||
                    line.IndexOf('\r') >= 0 || line.IndexOf('\n') >= 0)
                { WriteError(stream, 400, "Bad Request"); return; }
                string key = line.Substring(0, colon);
                if (!Regex.IsMatch(key, "^[A-Za-z0-9!#$%&'*+.^_`|~-]+$") || headers.ContainsKey(key))
                { WriteError(stream, 400, "Bad Request"); return; }
                headers.Add(key, line.Substring(colon + 1).Trim(' ', '\t'));
            }
            string value;
            if (!headers.TryGetValue("Host", out value) || value != "127.0.0.1:17643")
            { WriteError(stream, 400, "Bad Request"); return; }
            if (headers.ContainsKey("Transfer-Encoding") ||
                (headers.TryGetValue("Content-Length", out value) && value != "0"))
            { WriteError(stream, 400, "Bad Request"); return; }
            // Extensions use their own host permission. Ordinary web origins are not allowed,
            // and no Access-Control-Allow-Origin header is ever emitted.
            if (headers.TryGetValue("Origin", out value) &&
                !Regex.IsMatch(value, "^chrome-extension://[a-p]{32}$", RegexOptions.CultureInvariant))
            { WriteError(stream, 403, "Forbidden"); return; }

            string authorization;
            if (!headers.TryGetValue("Authorization", out authorization) ||
                !authorization.StartsWith("Bearer ", StringComparison.Ordinal))
            { WriteError(stream, 403, "Forbidden"); return; }
            byte[] candidate = ParseToken(authorization.Substring(7));
            byte[] payload;
            string name;
            long version;
            lock (gate)
            {
                if (stopping || token == null || bundle == null || DateTime.UtcNow >= expiresUtc ||
                    !TokensEqual(candidate, token))
                { WriteError(stream, 403, "Forbidden"); return; }
                payload = bundle;
                name = fileName;
                version = publicationVersion;
            }
            if (candidate != null) Array.Clear(candidate, 0, candidate.Length);

            WriteHeader(stream, 200, "OK", "application/zip", payload.Length, name);
            stream.Write(payload, 0, payload.Length);
            stream.Flush();
            lock (gate)
            {
                if (version == publicationVersion && Object.ReferenceEquals(payload, bundle))
                    Interlocked.Increment(ref downloadCount);
            }
        }

        private static byte[] ParseToken(string text)
        {
            if (text.Length != 64) return null;
            byte[] result = new byte[32];
            int invalid = 0;
            for (int i = 0; i < result.Length; i++)
            {
                int a = HexDigit(text[2 * i]);
                int b = HexDigit(text[2 * i + 1]);
                invalid |= a | b;
                result[i] = (byte)((a << 4) | b);
            }
            if (invalid < 0) { Array.Clear(result, 0, result.Length); return null; }
            return result;
        }

        private static int HexDigit(char c)
        {
            if (c >= '0' && c <= '9') return c - '0';
            if (c >= 'a' && c <= 'f') return c - 'a' + 10;
            return -1;
        }

        private static bool TokensEqual(byte[] candidate, byte[] expected)
        {
            if (candidate == null || candidate.Length != 32 || expected.Length != 32) return false;
            int difference = 0;
            for (int i = 0; i < 32; i++) difference |= candidate[i] ^ expected[i];
            return difference == 0;
        }

        private static void WriteError(NetworkStream stream, int status, string reason)
        {
            byte[] bytes = Encoding.ASCII.GetBytes(reason + "\n");
            WriteHeader(stream, status, reason, "text/plain; charset=us-ascii", bytes.Length, null);
            stream.Write(bytes, 0, bytes.Length);
            stream.Flush();
        }

        private static void WriteHeader(NetworkStream stream, int status, string reason,
            string contentType, int length, string downloadName)
        {
            StringBuilder text = new StringBuilder();
            text.Append("HTTP/1.1 ").Append(status).Append(' ').Append(reason).Append("\r\n");
            text.Append("Content-Type: ").Append(contentType).Append("\r\n");
            text.Append("Content-Length: ").Append(length.ToString(CultureInfo.InvariantCulture)).Append("\r\n");
            text.Append("Connection: close\r\nCache-Control: no-store\r\nPragma: no-cache\r\n");
            text.Append("X-Content-Type-Options: nosniff\r\n");
            if (downloadName != null)
            {
                text.Append("X-MTZ-Filename: ").Append(downloadName).Append("\r\n");
                text.Append("Content-Disposition: attachment; filename=\"").Append(downloadName).Append("\"\r\n");
            }
            text.Append("\r\n");
            byte[] bytes = Encoding.ASCII.GetBytes(text.ToString());
            stream.Write(bytes, 0, bytes.Length);
        }

        private void SetError(string message) { lock (gate) { lastError = message; } }
        private bool IsCurrentListener(TcpListener candidate)
        {
            lock (gate) { return Object.ReferenceEquals(listener, candidate); }
        }
        private void ThrowIfDisposed() { if (disposed) throw new ObjectDisposedException("Mtz.LogBridge"); }
    }
}
