# Third-party notices

`flutter_scene_riglogic` compiles Epic Games' **OpenRigLogic** (the RigLogic
rig evaluator and the DNA file library), vendored as a git submodule in
`third_party/OpenRigLogic` and pinned to its `5.8` release branch, into its
native libraries and its WebAssembly module.

OpenRigLogic is distributed under the MIT License. Its notice is also the second
entry of this package's `LICENSE`, which Flutter collects into every app's
license page:

```
MIT License

Copyright (c) 2026 Epic Games, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in 
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN 
THE SOFTWARE.
```

The package contains no MetaHuman characters or other Epic content. Its test
fixture (`test/fixtures/fixture.dna`) is a synthetic rig written by
`native/tools/make_dna.cpp`.
