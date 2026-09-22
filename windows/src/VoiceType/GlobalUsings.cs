// WindowsDesktop SDK 的隐式 using 刻意不包含 System.IO（避免与 System.Windows.Shapes.Path
// 歧义）；本项目大量使用文件 API，显式补回，用到 Shapes.Path 的文件按需全限定。
global using System.IO;
