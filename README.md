# BrycensRanch.StaticLink.Avalonia

Static native libraries for Avalonia single-file NativeAOT publishing.

## Why use this?

Building an Avalonia program using NativeAOT generally entails dealing with complex native dependencies. This setup provides those native dependencies pre-compiled and statically linked, giving you a clean, real single-file deployment without the runtime loading headaches.

- Statically links SkiaSharp with unused features (like PDF and Skottie) stripped out to shrink your final binary size.
- Compiles ANGLE binaries strictly for Windows, keeping your NuGet footprint lean across other platforms.
- Adds built-in support for FreeBSD (x64/arm64) and Linux ARMHF (glibc/musl), compiled using stable Ubuntu 18.04 and Alpine 3.19 sysroots.
- Pulls from an updated ANGLE branch containing upstream fixes ahead of official SkiaSharp releases.

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


### Build config

This package's SkiaSharp build options compared to the `SkiaSharp.NativeAssets` packages are minimal.
They are optimized around Avalonia apps. If your app extensively uses SkiaSharp's optional features, this package may not be for you.

SkiaSharp:
<details>

```toml
target_os = "$TARGET_OS"
target_cpu = "$TARGET_CPU"
is_official_build = true
is_static_skiasharp = true
skia_enable_tools = false
skia_enable_ganesh = true
skia_enable_graphite = false
skia_enable_pdf = false
skia_enable_skottie = false
skia_use_dng_sdk = false
skia_use_fontconfig = true
skia_use_freetype = true
skia_use_harfbuzz = false
skia_use_icu = false
skia_use_piex = false
skia_use_system_expat = false
skia_use_system_freetype2 = false
skia_use_system_libjpeg_turbo = false
skia_use_system_libpng = false
skia_use_system_libwebp = false
skia_use_system_zlib = false
skia_use_vulkan = false
skia_use_xps = false
skia_use_partition_alloc = false
cc = "$CC"
cxx = "$CXX"
ar = "llvm-ar"
extra_cflags = [
  "-DSKIA_C_DLL",
  "-DHAVE_SYSCALL_GETRANDOM",
  "-DXML_DEV_URANDOM",
]
extra_cflags_cc = [ "-frtti", "-Wno-psabi" ]
extra_ldflags = []
```
</details>

ANGLE:
<details>

```toml
target_os = "win"
target_cpu = "$TargetCpu"
is_debug = false
is_component_build = false
treat_warnings_as_errors = false
is_clang = true
use_lld = false
use_custom_libcxx = false
use_thin_lto = false
symbol_level = 0
angle_build_tests = false
build_angle_deqp_tests = false
angle_enable_swiftshader = false
angle_enable_vulkan = false
angle_enable_wgpu = false
extra_cflags = [ "/D_SILENCE_CXX20_OLD_SHARED_PTR_ATOMIC_SUPPORT_DEPRECATION_WARNING" ]
```

</details>
## Native Package Automation

`.github/workflows/nuget-avalonia-native.yml` runs daily and checks the latest stable `Avalonia` version on NuGet.org. If `BrycensRanch.StaticLink.Avalonia.Native.<AvaloniaVersion>.1` does not exist, it builds both macOS architectures from the matching Avalonia source tag, runs NativeAOT smoke tests, and publishes the package with NuGet Trusted Publishing.