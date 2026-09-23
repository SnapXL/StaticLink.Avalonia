# BrycensRanch.StaticLink.Avalonia

Static native libraries for Avalonia single-file NativeAOT publishing.

Differences from upstream:

- Uses a more up-to-date ANGLE branch, so you get upstream fixes and improvements that upstream's pinned branch does not have yet.
- ANGLE is built on Windows only. Upstream builds it on every platform, but Avalonia only uses it on Windows. This results in a smaller NuGet package.
- Linux static archives are built on Ubuntu 22.04, which improves glibc portability.
- FreeBSD x64 and arm64 are supported.

## Install

Choose the static graphics package that matches the Avalonia and SkiaSharp major versions used by your application.

| Avalonia version | SkiaSharp version | `BrycensRanch.StaticLink.Avalonia` version |
| --- | --- | --- |
| 12 | 4.154.0-preview.1 | `4.154.0-preview.1-8059.1` |

Example:
```xml
<ItemGroup>
  <PackageReference Include="Avalonia" Version="12.1.3" />
  <PackageReference Include="BrycensRanch.StaticLink.Avalonia" Version="4.154.0-preview.1-8059.1" />
</ItemGroup>
```

### macOS

For macOS, also reference `BrycensRanch.StaticLink.Avalonia.Native`. This package contains `libAvaloniaNative.a`, so its version must match the Avalonia version used by the application.

```xml
<!-- Avalonia 12.1.3 -->
<PackageReference Include="BrycensRanch.StaticLink.Avalonia.Native" Version="12.1.3.1" />
```

Add only the `BrycensRanch.StaticLink.Avalonia.Native` reference matching your Avalonia version.

On macOS, only Avalonia 12 with skia3/4 supports Metal. Avalonia 11 fully static apps must use OpenGL or Software because its Metal path dynamically loads `libSkiaSharp`.

## Publish

```bash
dotnet publish -c Release -r win-x64 -p:PublishAot=true
```

Use the RID you need, such as `win-x86`, `linux-x64`, `linux-arm64`, `osx-arm64`, or `osx-x64`.


## Native Package Automation

`.github/workflows/nuget-avalonia-native.yml` runs daily and checks the latest stable `Avalonia` version on NuGet.org. If `BrycensRanch.StaticLink.Avalonia.Native.<AvaloniaVersion>.1` does not exist, it builds both macOS architectures from the matching Avalonia source tag, runs NativeAOT smoke tests, and publishes the package with NuGet Trusted Publishing.