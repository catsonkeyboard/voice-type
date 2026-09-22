using System.Runtime.InteropServices;
using System.Text;

namespace VoiceType.Interop.SherpaOnnx;

/// <summary>
/// 为 C API 结构体的 const char* 字段分配 UTF-8 内存并集中释放。
/// 不用 CharSet.Ansi 封送：Windows ANSI 代码页下中文路径会乱码，C API 约定是 UTF-8。
/// </summary>
internal sealed class NativeStringPool : IDisposable
{
    private readonly List<IntPtr> _ptrs = [];

    /// <summary>null/空串返回 IntPtr.Zero（C 侧对空指针与 "" 同样处理）</summary>
    public IntPtr Alloc(string? s)
    {
        if (string.IsNullOrEmpty(s))
            return IntPtr.Zero;
        byte[] bytes = Encoding.UTF8.GetBytes(s);
        IntPtr p = Marshal.AllocHGlobal(bytes.Length + 1);
        Marshal.Copy(bytes, 0, p, bytes.Length);
        Marshal.WriteByte(p, bytes.Length, 0);
        _ptrs.Add(p);
        return p;
    }

    public void Dispose()
    {
        foreach (IntPtr p in _ptrs)
            Marshal.FreeHGlobal(p);
        _ptrs.Clear();
    }
}

internal static class NativeUtf8
{
    /// <summary>读取 C 返回的 const char*（UTF-8）；空指针返回空串。</summary>
    public static string Read(IntPtr p)
        => p == IntPtr.Zero ? "" : Marshal.PtrToStringUTF8(p) ?? "";
}
