---
title: Open CASCADE and replacing the library
description: SimplMaker's geometry kernel is Open CASCADE Technology (LGPL 2.1). Where its source is, how it is built, and how to replace it with your own build.
---

SimplMaker's geometry kernel, the part that makes extrusions, fillets, booleans and STEP files, is [Open CASCADE Technology](https://dev.opencascade.org) (OCCT), version 8.0.1. OCCT is free software under the **GNU LGPL 2.1 with the Open CASCADE exception**. SimplMaker itself is not, but the licence lets you replace OCCT with your own build. This page says how.

## What is inside the app

- OCCT is a **separate library**, `libSimplOCCT.dylib`, in the app's `Contents/Frameworks` folder. SimplMaker links to it dynamically.
- It is built **unmodified** from the upstream source, tag `V8_0_1`: [github.com/Open-Cascade-SAS/OCCT](https://github.com/Open-Cascade-SAS/OCCT). We have not patched OCCT. If we ever do, we publish the changes here.
- The licence texts are under **SimplMaker → About SimplMaker**.

## Get the source

The complete OCCT source for the version in the app is the `V8_0_1` tag of the repository above. If that is ever not available, write to [{{support_email}}](mailto:{{support_email}}) and we will send you a copy. The offer is open for at least three years after you received SimplMaker.

## Build it the way SimplMaker does

You need Xcode's command line tools, CMake and Ninja on a Mac with Apple silicon. SimplMaker's own build configures OCCT like this:

```
git clone --depth 1 --branch V8_0_1 https://github.com/Open-Cascade-SAS/OCCT.git occt-src
cmake -S occt-src -B occt-build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$PWD/occt-install \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_LIBRARY_TYPE=Static \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
  -DBUILD_MODULE_FoundationClasses=ON -DBUILD_MODULE_ModelingData=ON \
  -DBUILD_MODULE_ModelingAlgorithms=ON -DBUILD_MODULE_Visualization=ON \
  -DBUILD_MODULE_ApplicationFramework=ON -DBUILD_MODULE_DataExchange=ON \
  -DBUILD_MODULE_Draw=OFF -DBUILD_MODULE_DETools=OFF \
  -DBUILD_DOC_Overview=OFF -DBUILD_SAMPLES_QT=OFF \
  -DUSE_FREETYPE=OFF -DUSE_OPENGL=OFF -DUSE_GLES2=OFF -DUSE_XLIB=OFF \
  -DUSE_TK=OFF -DUSE_TCL=OFF -DUSE_TBB=OFF -DUSE_VTK=OFF \
  -DUSE_FREEIMAGE=OFF -DUSE_FFMPEG=OFF -DUSE_OPENVR=OFF \
  -DUSE_RAPIDJSON=OFF -DUSE_DRACO=OFF
cmake --build occt-build --parallel
cmake --install occt-build
```

That makes one static archive per OCCT toolkit. SimplMaker merges them into one dynamic library:

```
libtool -static -o libSimplOCCT.a $(find occt-install -name 'libTK*.a')
clang++ -dynamiclib -arch arm64 -mmacosx-version-min=26.0 -o libSimplOCCT.dylib \
  -install_name @rpath/libSimplOCCT.dylib -Wl,-force_load,libSimplOCCT.a \
  -framework Foundation -framework AppKit -framework IOKit -lc++
```

## Replace the library

1. Quit SimplMaker.
2. Copy your `libSimplOCCT.dylib` over the one in `SimplMaker.app/Contents/Frameworks/`.
3. macOS checks an app's signature, so sign the app again. An ad-hoc signature is enough:

```
codesign --force --deep --sign - /Applications/SimplMaker.app
```

:::note
Your copy has to be a **compatible build**: the same OCCT version, or one with the same interface, and the same options as above. SimplMaker calls OCCT directly and cannot use a library with a different interface.
:::

:::note
Re-signing replaces our signature, so macOS no longer sees the app as signed by us. A SimplMaker update replaces your library with the standard one.
:::

You may modify OCCT for your own use and reverse engineer SimplMaker as far as needed to debug those changes. The [Licence agreement](/eula/) does not restrict either.

## Other open-source components

The other components SimplMaker includes, such as DelaBella, Sparkle and Lucide, and their licences are listed under **SimplMaker → About SimplMaker**.
