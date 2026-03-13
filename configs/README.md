# OpenWrt 配置入库方案

这个目录用于存放可以提交到 git 的配置源文件，而不是直接提交顶层的 .config。

推荐原则：

1. 顶层 .config 只作为本地构建产物，不作为仓库中的事实来源。
2. 板级固定内容放在代码树里维护，例如 DTS、target 目录补丁、base-files 覆盖文件。
3. 固件选择项和包选择项用最小差异配置保存到 configs 目录。
4. 对于像 BusyBox 默认值这种无法通过 seed 稳定回放的隐藏符号，用 post-defconfig fragment 保存。
5. 每个板子一份 seed 配置，命名使用可唯一识别的 target 和 device 名称。

当前建议的目录约定：

- configs/devices/mediatek_filogic_myboard_my-mt7981.seed
- configs/fragments/mediatek_filogic_myboard_my-mt7981.postconfig

推荐工作流：

1. 在 Linux/WSL/Git Bash 构建环境中执行 menuconfig 调整配置。
2. 执行 ./scripts/diffconfig.sh > configs/devices/mediatek_filogic_myboard_my-mt7981.seed 导出最小配置。
3. 对于 seed 无法稳定表达的隐藏符号，维护到对应的 post-defconfig fragment。
4. 不提交顶层 .config，只提交 seed、fragment 和真正的源码改动。
5. 新机器或 CI 恢复配置时，先用 seed 生成 .config，再应用 fragment，最后执行编译。

恢复配置示例：

```sh
cp configs/devices/mediatek_filogic_myboard_my-mt7981.seed .config
make defconfig
make
```

也可以直接使用仓库根目录的短命令：

```sh
./build.sh
```

底层实现仍然在 `scripts/build-from-seed.sh`，如果需要单独调试也可以直接调用它。

只恢复 .config 不编译：

```sh
./build.sh --config-only
```

指定其他 seed 并传递 make 参数：

```sh
./build.sh configs/devices/mediatek_filogic_myboard_my-mt7981.seed -- V=s
```

如果只是传普通 make 参数，也可以不写 `--`：

```sh
./build.sh V=s
```

只重编 BusyBox 并重新生成最终固件：

```sh
./build.sh --package busybox --image -- V=s
```

只重编内核/设备树并重新生成最终固件：

```sh
./build.sh --kernel --image -- V=s
```

只执行局部编译，不重建 .config：

```sh
./build.sh --reuse-config --package busybox -- V=s
```

先看将要执行的 make 命令，不真正编译：

```sh
./build.sh --package busybox --image --dry-run -- V=s
```

显式指定并发数：

```sh
./build.sh --package busybox --image --jobs 8 -- V=s
```

更新配置示例：

```sh
make menuconfig
./scripts/diffconfig.sh > configs/devices/mediatek_filogic_myboard_my-mt7981.seed
```

隐藏符号维护示例：

像 CONFIG_BUSYBOX_DEFAULT_TFTP 这类 BusyBox 默认值会出现在完整 .config 中，但它们本身不是稳定可回放的 seed 输入。对于这类配置，应该写入 post-defconfig fragment，并由构建脚本在 make defconfig 之后补回到顶层 .config。

注意：

- 如果 .config 之前已经被 git 跟踪，修改 .gitignore 还不够，需要执行一次 git rm --cached .config。
- 顶层 .config.old 仍然应当继续忽略。
- 如果某些选项必须长期默认开启，优先考虑放到对应 package 或 target 的默认配置逻辑里，而不是长期依赖人工 menuconfig。
- seed 不是 .config 的完整复制，而是相对默认值的最小差异配置；真正编译前仍然需要通过 make defconfig 展开成完整 .config。
- 对隐藏符号，正确做法不是强行塞进 seed，而是使用 post-defconfig fragment 或把需求下沉到源码默认值。
- `--package busybox --image` 这类用法会执行局部 package 编译，然后自动追加 `package/install` 和 `target/install` 来生成最终固件。
- 对 DTS、内核驱动、target/linux 下的改动，优先使用 `--kernel --image`。
- 如果没有显式传 `--jobs` 或 `-j` 参数，脚本会自动用 `nproc` 或 `getconf _NPROCESSORS_ONLN` 探测并发数。