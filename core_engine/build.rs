use std::env;

fn main() {
    let target = env::var("TARGET").unwrap_or_default();
    let ios = target.contains("ios");
    let default_root = format!(
        "{}/vendor/sherpa-onnx-v1.13.8-osx-arm64-shared",
        env!("CARGO_MANIFEST_DIR")
    );
    let root = env::var("SHERPA_ONNX_DIR").unwrap_or(default_root);
    let include = format!("{root}/include");
    let lib = format!("{root}/lib");

    cc::Build::new()
        .file("csrc/asr_shim.c")
        .include(&include)
        .warnings(true)
        .compile("ovc_asr_shim");

    println!("cargo:rustc-link-search=native={lib}");
    if ios {
        // iOS ships sherpa-onnx and onnxruntime as STATIC archives (there is no
        // dylib to load at run time, and an rpath has nothing to point at). The
        // ordering matters: sherpa calls into onnxruntime, so it comes first.
        println!("cargo:rustc-link-lib=static=sherpa-onnx");
        println!("cargo:rustc-link-lib=static=onnxruntime");
        println!("cargo:rustc-link-lib=c++");
        for framework in ["Accelerate", "CoreML", "Foundation"] {
            println!("cargo:rustc-link-lib=framework={framework}");
        }
        // onnxruntime and sherpa are C++, and their code calls
        // ___isPlatformVersionAtLeast -- which the system linker resolves out of
        // clang's own compiler-rt archive. rustc does not add that for iOS.
        let (sdk, rt) = if target.contains("sim") {
            ("iphonesimulator", "iossim")
        } else {
            ("iphoneos", "ios")
        };
        if let Ok(out) = std::process::Command::new("xcrun")
            .args(["--sdk", sdk, "clang", "-print-resource-dir"])
            .output()
        {
            let dir = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if !dir.is_empty() {
                // A path, not -l: the compiler-rt archive ships as a universal
                // binary, which rustc refuses to add itself but the linker takes.
                println!("cargo:rustc-link-arg={dir}/lib/darwin/libclang_rt.{rt}.a");
            }
        }
    } else {
        println!("cargo:rustc-link-lib=dylib=sherpa-onnx-c-api");
        println!("cargo:rustc-link-arg=-Wl,-rpath,{lib}");
    }
    println!("cargo:rerun-if-changed=csrc/asr_shim.c");
    println!("cargo:rerun-if-env-changed=SHERPA_ONNX_DIR");
    // The deployment target ends up in every object's LC_BUILD_VERSION. Without
    // this line a change to it does not re-run the script, the old objects are
    // reused, and the app links against a core built for a newer iOS than the
    // one it claims to support -- which the linker warns about once per object.
    println!("cargo:rerun-if-env-changed=IPHONEOS_DEPLOYMENT_TARGET");
}
