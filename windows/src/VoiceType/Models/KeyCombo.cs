using System.Text.Json.Serialization;
using VoiceType.Interop;

namespace VoiceType.Models;

[JsonConverter(typeof(JsonStringEnumConverter<HotkeyModifiers>))]
[Flags]
public enum HotkeyModifiers
{
    None = 0,
    Alt = (int)WinHotkey.Modifiers.Alt,
    Control = (int)WinHotkey.Modifiers.Control,
    Shift = (int)WinHotkey.Modifiers.Shift,
    Win = (int)WinHotkey.Modifiers.Win,
}

/// <summary>全局快捷键组合（Windows 虚拟键码 + 修饰键）。</summary>
public sealed record KeyCombo(
    [property: JsonPropertyName("modifiers")] HotkeyModifiers Modifiers,
    [property: JsonPropertyName("vk")] uint VirtualKey,
    [property: JsonPropertyName("display")] string Display)
{
    /// <summary>
    /// 默认 Ctrl+Alt+Space。macOS 端默认 ⌥Space，但 Alt+Space 是 Windows
    /// 系统窗口菜单快捷键，RegisterHotKey 无法注册，故迁移后默认组合改为 Ctrl+Alt+Space。
    /// </summary>
    public static readonly KeyCombo Default = new(
        HotkeyModifiers.Control | HotkeyModifiers.Alt, 0x20, "Ctrl+Alt+Space");

    public static KeyCombo Create(HotkeyModifiers modifiers, uint vk) =>
        new(modifiers, vk, KeyNames.Display(modifiers, vk));
}

/// <summary>虚拟键码 → 显示名。</summary>
public static class KeyNames
{
    private static readonly Dictionary<uint, string> Special = new()
    {
        [0x20] = "Space",
        [0x0D] = "Enter",
        [0x09] = "Tab",
        [0x08] = "Backspace",
        [0x2E] = "Delete",
        [0x2D] = "Insert",
        [0x1B] = "Esc",
        [0x14] = "CapsLock",
        [0x21] = "PageUp",
        [0x22] = "PageDown",
        [0x23] = "End",
        [0x24] = "Home",
        [0x25] = "Left",
        [0x26] = "Up",
        [0x27] = "Right",
        [0x28] = "Down",
        [0x90] = "NumLock",
        [0x5B] = "Win",
        [0x5C] = "Win",
        [0x1D] = "Ctrl",
        [0x11] = "Ctrl",
        [0xA2] = "Ctrl",
        [0x12] = "Alt",
        [0xA4] = "Alt",
        [0x10] = "Shift",
        [0xA0] = "Shift",
    };

    public static string Display(HotkeyModifiers modifiers, uint vk)
    {
        var sb = new System.Text.StringBuilder();
        if (modifiers.HasFlag(HotkeyModifiers.Control)) sb.Append("Ctrl+");
        if (modifiers.HasFlag(HotkeyModifiers.Alt)) sb.Append("Alt+");
        if (modifiers.HasFlag(HotkeyModifiers.Shift)) sb.Append("Shift+");
        if (modifiers.HasFlag(HotkeyModifiers.Win)) sb.Append("Win+");
        sb.Append(Name(vk));
        return sb.ToString();
    }

    public static string Name(uint vk)
    {
        if (Special.TryGetValue(vk, out string? name))
            return name;
        if (vk is >= 0x70 and <= 0x87)
            return $"F{vk - 0x6F}";
        if (vk is >= 0x30 and <= 0x39 or >= 0x41 and <= 0x5A)
            return ((char)vk).ToString();
        return $"键码0x{vk:X2}";
    }
}
