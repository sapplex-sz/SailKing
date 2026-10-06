# 海王原生本地翻译运行时

本项目复用工作区“本地翻译软件”中已经验证的 C ABI 推理层，并保留源码、补丁及全部许可证。UI、引擎路由、模型配置和API连接为海王独立实现。

- llama.cpp STQ PR #22836 固定提交 `1e411d8f5a1e23525fa3265dfb4bd76265465397`，加 `Patches/hy-mt2-legacy-stq.patch`。
- 当前静态 XCFramework 仅 macOS 15+ arm64，CPU ARM NEON / Accelerate；iOS工作台使用 API 或 Apple Translation，不链接此框架。
- 默认模型 Tencent Hy-MT2 1.8B 1.25-bit，461,860,800 字节（440.46 MiB），Apache-2.0。可选 Q4 1,133,080,448 字节。固定版本、文件尺寸及 SHA-256 见 `Sources/HaiwangCore/EngineConfiguration.swift`。
- 可复现构建：`bash scripts/build-runtime.sh`；无 Python / Ollama 运行依赖。
- 单实例串行推理；上下文4096，最多2048输出token；实际取消标志可中断加载/prefill/生成；超限返回错误，不把截断输出当译文。模型默认按需加载并复用。
- 使用官方单user提示及采样参数；手动源语言作为完整英文语言名进入提示。订单号、SKU、链接和邮箱添加同值术语并进行输出校验。该校验不是完整语义正确性验证。
- 模型下载仅走固定 Hugging Face HTTPS 版本，下载完成后流式校验尺寸/SHA-256，再原子写入安装收据。不会加载用户配置的远程代码。
- 模型配置后台只支持当前 `hymt2-gguf` 运行时。更换不同架构的模型需要先增加对应原生运行时，不能仅改模型名称。

许可证在 `Resources/Licenses/`，一并打包进App。官方上游：[Hy-MT2](https://huggingface.co/tencent/Hy-MT2-1.8B)、[llama.cpp STQ PR](https://github.com/ggml-org/llama.cpp/pull/22836)。

## Windows runtime

Windows builds the same C ABI as `CHaHaRuntime.dll` against the pinned llama.cpp source. The platform-specific thread-count query is guarded so the Mac implementation is unchanged. The Windows preview uses the Hy-MT2 Q4 model; it does not apply the ARM-only legacy STQ model mapping. The broker selects the optimized AVX2 runtime only when Windows and the CPU support all required instructions, with a baseline x64 runtime as fallback. Both variants are packaged and checked independently. Ordinary Pinyin does not load the model or inference runtime. No external inference server is needed. Build and dependency verification are managed by `windows/scripts/build.ps1`.
