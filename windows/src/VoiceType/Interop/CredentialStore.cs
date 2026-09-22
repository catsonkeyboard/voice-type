using System.ComponentModel;
using System.Runtime.InteropServices;

namespace VoiceType.Interop;

/// <summary>
/// Windows 凭据管理器薄封装（对应 macOS KeychainStore.kSecClassGenericPassword）。
/// Target 固定为 "VoiceType/&lt;account&gt;"，类型 GENERIC，CurrentUser 范围。
/// </summary>
public interface ICredentialStore
{
    string? Get(string account);
    /// <summary>set 空字符串等价删除。</summary>
    void Set(string value, string account);
}

public sealed class CredentialStore : ICredentialStore
{
    private const string Prefix = "VoiceType/";
    private const int CredTypeGeneric = 1;
    private const uint CredPersistLocalMachine = 2;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIALW
    {
        public int Flags;
        public int Type;
        public IntPtr TargetName;
        public IntPtr Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public IntPtr CredentialBlob;
        public int CredentialBlobSize;
        public uint Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public IntPtr TargetAlias;
        public IntPtr UserName;
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWriteW(ref CREDENTIALW credential, uint flags);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredReadW(
        string target, int type, uint reservedFlag, out IntPtr credentialPtr);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDeleteW(string target, int type, uint reservedFlag);

    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr buffer);

    public string? Get(string account)
    {
        string target = Prefix + account;
        if (!CredReadW(target, CredTypeGeneric, 0, out IntPtr ptr))
        {
            int err = Marshal.GetLastWin32Error();
            if (err == 1168) return null;  // ERROR_NOT_FOUND
            throw new Win32Exception(err, $"读取凭据失败（{target}）");
        }
        try
        {
            var cred = Marshal.PtrToStructure<CREDENTIALW>(ptr);
            if (cred.CredentialBlobSize <= 0 || cred.CredentialBlob == IntPtr.Zero)
                return "";
            byte[] bytes = new byte[cred.CredentialBlobSize];
            Marshal.Copy(cred.CredentialBlob, bytes, 0, bytes.Length);
            return System.Text.Encoding.UTF8.GetString(bytes);
        }
        finally
        {
            CredFree(ptr);
        }
    }

    public void Set(string value, string account)
    {
        string target = Prefix + account;
        CredDeleteW(target, CredTypeGeneric, 0);  // 覆盖写：先删（不存在也无妨）
        if (string.IsNullOrEmpty(value))
            return;
        byte[] blob = System.Text.Encoding.UTF8.GetBytes(value);
        IntPtr blobPtr = Marshal.AllocHGlobal(blob.Length);
        try
        {
            Marshal.Copy(blob, 0, blobPtr, blob.Length);
            var targetPtr = Marshal.StringToHGlobalUni(target);
            var userPtr = Marshal.StringToHGlobalUni("VoiceType");
            try
            {
                var cred = new CREDENTIALW
                {
                    Type = CredTypeGeneric,
                    TargetName = targetPtr,
                    CredentialBlob = blobPtr,
                    CredentialBlobSize = blob.Length,
                    Persist = CredPersistLocalMachine,
                    UserName = userPtr,
                };
                if (!CredWriteW(ref cred, 0))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), $"写入凭据失败（{target}）");
            }
            finally
            {
                Marshal.FreeHGlobal(targetPtr);
                Marshal.FreeHGlobal(userPtr);
            }
        }
        finally
        {
            Marshal.FreeHGlobal(blobPtr);
        }
    }
}

/// <summary>测试 / 设计期用的内存实现。</summary>
public sealed class InMemoryCredentialStore : ICredentialStore
{
    private readonly Dictionary<string, string> _map = [];

    public string? Get(string account) => _map.TryGetValue(account, out string? v) ? v : null;

    public void Set(string value, string account)
    {
        if (string.IsNullOrEmpty(value))
            _map.Remove(account);
        else
            _map[account] = value;
    }
}
