#!/usr/bin/env bash
set -e

# 用 sh install.sh 调用时也确保以 bash 运行（用到 BASH_SOURCE / /dev/tcp 等 bash 特性）
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" "$@"
fi

cd "$(dirname "$0")/.."
ROOT_DIR="$(pwd)"

# ---------- 平台检测 ----------
# Git Bash / MSYS2 / Cygwin 的 uname 分别是 MINGW64_NT-* / MSYS_NT-* / CYGWIN_NT-*
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1; PLATFORM="Windows (Git Bash)" ;;
    *)                    IS_WINDOWS=0; PLATFORM="Linux" ;;
esac

# Git Bash 下没有 sudo / apt / systemctl；Linux 下以 root 运行时也不需要 sudo
if [ "$IS_WINDOWS" -eq 1 ] || ! command -v sudo >/dev/null 2>&1 || [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

echo "╔══════════════════════════════════════════════════╗"
echo "║   Local AI Gateway - 一键安装脚本 (NVIDIA GPU)    ║"
echo "╚══════════════════════════════════════════════════╝"
echo "   平台: $PLATFORM"

# ---------- 1. 系统依赖 ----------
echo ""
echo "▶ [1/6] 安装系统依赖..."
if [ "$IS_WINDOWS" -eq 1 ]; then
    echo "   Git Bash 无 sudo / apt，跳过系统包安装，改为检查外部命令。"
    MISSING=""
    for cmd in python git curl ffmpeg jq cmake; do
        command -v "$cmd" >/dev/null 2>&1 || MISSING="$MISSING $cmd"
    done
    if [ -n "$MISSING" ]; then
        echo "   ⚠️  缺少:$MISSING"
        echo "      请在 Windows 侧安装并加入 PATH："
        echo "      Python 3.10+ / Git for Windows / FFmpeg / jq / CMake + MSVC + CUDA Toolkit"
        echo "      (ffmpeg / jq / cmake 缺失不会中断本脚本，但会影响对应功能)"
    else
        echo "   ✅ 基础命令齐全"
    fi
else
    $SUDO apt update
    $SUDO apt install -y \
        python3 python3-venv python3-pip \
        nvidia-cuda-toolkit nvidia-cudnn \
        git wget curl ffmpeg jq \
        libcurl4-openssl-dev libssl-dev \
        redis-server
fi

# 验证 NVIDIA（Windows 驱动可能没把 nvidia-smi 放进 PATH）
NVIDIA_SMI="nvidia-smi"
if ! command -v nvidia-smi >/dev/null 2>&1 && [ "$IS_WINDOWS" -eq 1 ]; then
    for candidate in "/c/Windows/System32/nvidia-smi.exe" \
                     "/c/Program Files/NVIDIA Corporation/NVMe/nvidia-smi.exe"; do
        if [ -x "$candidate" ]; then NVIDIA_SMI="$candidate"; break; fi
    done
fi
if ! "$NVIDIA_SMI" >/dev/null 2>&1; then
    echo "❌ ERROR: nvidia-smi not found. Please install NVIDIA drivers first."
    if [ "$IS_WINDOWS" -eq 1 ]; then
        echo "   Windows 下请确认 NVIDIA 驱动已装且 nvidia-smi.exe 在 PATH 中。"
    fi
    exit 1
fi
echo "✅ NVIDIA GPU detected:"
"$NVIDIA_SMI" --query-gpu=name,memory.total --format=csv,noheader || true

# ---------- 2. Python 虚拟环境 ----------
echo ""
echo "▶ [2/6] 创建 Python 虚拟环境..."
if [ "$IS_WINDOWS" -eq 1 ]; then
    PYTHON="${PYTHON_BIN:-python}"
    VENV_ACTIVATE="venv/Scripts/activate"
else
    PYTHON="${PYTHON_BIN:-python3}"
    VENV_ACTIVATE="venv/bin/activate"
fi
# 排除 Microsoft Store 的 python.exe 占位程序（直接运行检测，兼容绝对路径）
if ! "$PYTHON" --version >/dev/null 2>&1; then
    echo "❌ ERROR: $PYTHON 不可用，请安装 Python 3.10+ 并加入 PATH 后重跑。"
    exit 1
fi

# requirements.txt 锁定的依赖（torch==2.4.0 / numpy==1.26.4）只提供 Python 3.10–3.12 的 wheel
python_version_ok() {
    "$1" -c 'import sys; sys.exit(0 if (3, 10) <= sys.version_info[:2] <= (3, 12) else 1)' >/dev/null 2>&1
}
if ! python_version_ok "$PYTHON"; then
    FOUND=""
    if [ "$IS_WINDOWS" -eq 1 ] && command -v py >/dev/null 2>&1; then
        # 默认 python 版本不满足时，尝试用 py launcher 自动找 3.10–3.12
        for v in 3.12 3.11 3.10; do
            CAND="$(py -"$v" -c 'import sys; print(sys.executable)' 2>/dev/null || true)"
            if [ -n "$CAND" ] && python_version_ok "$CAND"; then
                FOUND="$CAND"
                break
            fi
        done
    fi
    if [ -n "$FOUND" ]; then
        echo "   ⚠️  默认 Python 版本不受依赖支持，自动改用: $FOUND"
        PYTHON="$FOUND"
    else
        echo "❌ ERROR: requirements.txt 锁定的依赖（torch==2.4.0 / numpy==1.26.4）"
        echo "   只支持 Python 3.10–3.12，当前 Python 版本过高。请安装 Python 3.12："
        echo "   winget install Python.Python.3.12  或  https://www.python.org/downloads/"
        echo "   多版本共存时也可用 PYTHON_BIN=<python.exe 路径> 指定后重跑。"
        exit 1
    fi
fi

# 已有 venv 若是其它 Python 版本建的，直接重建，避免混装
if [ -f venv/pyvenv.cfg ]; then
    VENV_PY_VER="$(sed -n 's/^version *= *//p' venv/pyvenv.cfg 2>/dev/null | head -n1 | cut -d. -f1,2)"
    CUR_PY_VER="$("$PYTHON" -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
    if [ -n "$VENV_PY_VER" ] && [ "$VENV_PY_VER" != "$CUR_PY_VER" ]; then
        echo "   venv 由 Python $VENV_PY_VER 创建（当前用 $CUR_PY_VER），重建 venv..."
        rm -rf venv || { echo "❌ ERROR: 旧 venv 删除失败（可能被占用），请手动删除 venv/ 后重跑。"; exit 1; }
    fi
fi
"$PYTHON" -m venv venv

# Windows venv 的激活脚本在 Scripts/ 下；补一个 bin/activate 转发层，
# 让 start.sh / test.sh 里原有的 `source venv/bin/activate` 无需改动也能用。
if [ "$IS_WINDOWS" -eq 1 ] && [ ! -f venv/bin/activate ]; then
    mkdir -p venv/bin
    cat > venv/bin/activate <<'EOF'
# Git Bash 兼容层：转发到 Windows venv 的 Scripts/activate
_venv_bin_dir="$(cd "$(dirname "$BASH_SOURCE")" && pwd)"
if [ -f "$_venv_bin_dir/../Scripts/activate" ]; then
    source "$_venv_bin_dir/../Scripts/activate"
else
    echo "⚠️  venv/Scripts/activate 不存在，请手动激活虚拟环境" >&2
fi
unset _venv_bin_dir
EOF
fi
if [ ! -f "$VENV_ACTIVATE" ]; then
    echo "❌ ERROR: $VENV_ACTIVATE not found，虚拟环境创建失败。"
    exit 1
fi
source "$VENV_ACTIVATE"
# Windows 上 pip.exe 无法覆盖自身，必须用 `python -m pip` 升级，
# 否则报 "To modify pip, please run the following command" 并因 set -e 中断脚本
"$PYTHON" -m pip install --upgrade pip setuptools wheel \
    || echo "   ⚠️  pip 基础组件升级失败，使用现有版本继续"

# ---------- 3. Python 依赖 ----------
echo ""
echo "▶ [3/6] 安装 Python 依赖..."
if [ "$IS_WINDOWS" -eq 1 ] && [ "${SKIP_TORCH_CUDA:-0}" -ne 1 ]; then
    echo "   Windows 下 PyPI 的 torch 默认是 CPU 版，先装 CUDA 12.1 wheel..."
    echo "   (可用 SKIP_TORCH_CUDA=1 跳过；国内网络建议用镜像，如：)"
    echo "    TORCH_INDEX_URL=https://mirrors.aliyun.com/pytorch-wheels/cu121)"
    "$PYTHON" -m pip install torch==2.4.0 torchvision==0.19.0 \
        --index-url "${TORCH_INDEX_URL:-https://download.pytorch.org/whl/cu121}" \
        || echo "   ⚠️  CUDA 版 torch 安装失败，回退到 requirements.txt 默认源（CPU 版）"
fi
"$PYTHON" -m pip install -r requirements.txt || {
    echo "❌ ERROR: Python 依赖安装失败。国内网络建议加镜像源重跑："
    echo "   PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple sh scripts/install.sh"
    exit 1
}

# ---------- 4. Ollama ----------
echo ""
echo "▶ [4/6] 检查 Ollama..."
OLLAMA_OK=0
if ! command -v ollama >/dev/null 2>&1; then
    if [ "$IS_WINDOWS" -eq 1 ]; then
        echo "   ⚠️  未找到 ollama 命令。请从 https://ollama.com/download/windows 安装 OllamaSetup.exe，"
        echo "      安装后服务随托盘程序自动启动，再重跑本脚本即可拉取模型。"
    else
        echo "   Installing Ollama..."
        curl -fsSL https://ollama.com/install.sh | sh
        $SUDO systemctl enable ollama
        $SUDO systemctl start ollama
        sleep 3
        OLLAMA_OK=1
    fi
else
    if ! ollama list >/dev/null 2>&1; then
        echo "   Ollama 服务未响应，尝试启动..."
        if [ "$IS_WINDOWS" -eq 1 ]; then
            nohup ollama serve >/dev/null 2>&1 &
        else
            $SUDO systemctl start ollama >/dev/null 2>&1 || true
        fi
        sleep 3
    fi
    OLLAMA_OK=1
fi

# gateway 需要的模型名见 gateway/routers/chat.py 的 MODEL_MAP 与 agent/router.py
has_model() {  # 精确匹配模型名，避免子串误判（如 7b 误匹配 7b-instruct）
    ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$1"
}

# $1 = gateway 调用的模型名, $2 = Ollama 库中的模型名
ensure_model() {
    if has_model "$1"; then
        echo "   ✓ $1 已存在"
        return 0
    fi
    # 本地已有同内容模型（tag 不同）时建别名，避免重复下载数 GB
    if has_model "$2"; then
        ollama cp "$2" "$1" && { echo "   ✓ $1 ← 由本地 $2 创建别名"; return 0; }
    fi
    echo "   → 拉取 $2 ..."
    if ollama pull "$2"; then
        if [ "$1" != "$2" ]; then ollama cp "$2" "$1"; fi
        echo "   ✓ $1 就绪"
        return 0
    fi
    echo "   ⚠️  $2 拉取失败，可稍后手动执行: ollama pull $2"
    return 1
}

MODEL_FAIL=0
# 文本/视觉模型与 gateway 配置一致（.env 可用 OLLAMA_TEXT_MODEL / OLLAMA_VL_MODEL 覆盖）
TEXT_MODEL="$(grep -E '^OLLAMA_TEXT_MODEL=' .env 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '\"')"
TEXT_MODEL="${TEXT_MODEL:-qwen2.5:7b}"
VL_MODEL="$(grep -E '^OLLAMA_VL_MODEL=' .env 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '\"')"
VL_MODEL="${VL_MODEL:-qwen2.5-vl:7b}"

if has_model "$TEXT_MODEL"; then
    echo "   ✓ 文本模型 $TEXT_MODEL 已存在"
else
    # qwen2.5:7b-instruct 与官方 qwen2.5:7b 内容相同，本地已有则直接建别名，免下 4.7GB
    ensure_model "$TEXT_MODEL" "qwen2.5:7b-instruct" || MODEL_FAIL=1
fi

if has_model "$VL_MODEL"; then
    echo "   ✓ 视觉模型 $VL_MODEL 已存在，跳过 qwen2.5vl 下载"
else
    # Ollama 库名是 qwen2.5vl（无连字符），拉取后按 gateway 配置的名字建别名
    ensure_model "$VL_MODEL" "qwen2.5vl:7b" || MODEL_FAIL=1
fi

if [ "$MODEL_FAIL" -eq 0 ]; then
    echo "✅ Ollama ready"
else
    echo "   ⚠️  部分模型缺失，安装继续；补齐后 Gateway 对应能力即可用。"
fi

# ---------- 5. Redis ----------
echo ""
echo "▶ [5/6] 启动 Redis..."
redis_ping() {
    if command -v redis-cli >/dev/null 2>&1; then
        redis-cli ping 2>/dev/null | grep -q PONG
    else
        # Windows 常没有 redis-cli，退化为探测 6379 端口
        (echo > /dev/tcp/127.0.0.1/6379) >/dev/null 2>&1
    fi
}

if redis_ping; then
    echo "   Redis 已在运行"
elif [ "$IS_WINDOWS" -eq 1 ]; then
    echo "   Windows 无 systemctl，尝试其它方式启动 Redis..."
    if command -v redis-server >/dev/null 2>&1; then
        nohup redis-server >/dev/null 2>&1 &
        sleep 2
    elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        docker start redis >/dev/null 2>&1 || \
            docker run -d --name redis -p 6379:6379 redis:7-alpine >/dev/null 2>&1 || true
        sleep 2
    fi
else
    $SUDO systemctl enable redis-server
    $SUDO systemctl start redis-server
fi

if redis_ping; then
    echo "✅ Redis ready"
else
    echo "   ⚠️  Redis 未就绪，请手动启动后继续，例如："
    echo "      docker run -d --name redis -p 6379:6379 redis:7-alpine"
fi

# ---------- 6. 编译 SDCPP ----------
echo ""
echo "▶ [6/6] 编译 stable-diffusion.cpp (CUDA, REST API)..."
SDCPP_DIR="workers/sdcpp/stable-diffusion.cpp"
if [ -d "$SDCPP_DIR/build" ]; then
    echo "   SDCPP already compiled, skipping"
elif [ "$IS_WINDOWS" -eq 1 ] && [ "${SKIP_SDCPP:-0}" -eq 1 ]; then
    echo "   SKIP_SDCPP=1，跳过本地编译（start.sh 会回退到 Docker 容器）"
elif [ "$IS_WINDOWS" -eq 1 ]; then
    echo "   Git Bash 下改用 cmake --build（需 MSVC + CUDA Toolkit）..."

    # ---- CUDA Toolkit：已装检测 → 未装则自动安装 ----
    # 探测已安装的 CUDA（CUDA_PATH 或默认安装目录），成功时输出其 bin 目录
    find_cuda_bin() {
        local _cuda_root _d
        if [ -n "${CUDA_PATH:-}" ] && command -v cygpath >/dev/null 2>&1; then
            _cuda_root="$(cygpath -u "$CUDA_PATH" 2>/dev/null || true)"
            if [ -n "$_cuda_root" ] && [ -f "$_cuda_root/bin/nvcc.exe" ]; then
                echo "$_cuda_root/bin"
                return 0
            fi
        fi
        for _d in "/c/Program Files/NVIDIA GPU Computing Toolkit/CUDA"/*/bin; do
            if [ -f "$_d/nvcc.exe" ]; then
                echo "$_d"
                return 0
            fi
        done
        return 1
    }

    if command -v nvcc >/dev/null 2>&1; then
        echo "   ✓ CUDA Toolkit 已就绪"
    elif CUDA_BIN="$(find_cuda_bin)"; then
        # 已安装但当前终端 PATH 未刷新（装完没重开终端的常见场景）
        export PATH="$CUDA_BIN:$PATH"
        echo "   ✓ 检测到已安装的 CUDA，已补入本次会话 PATH: $CUDA_BIN"
    elif [ "${SKIP_CUDA_INSTALL:-0}" -eq 1 ]; then
        echo "   ⚠️  未检测到 CUDA Toolkit（SKIP_CUDA_INSTALL=1，跳过自动安装）"
    elif ! net session >/dev/null 2>&1; then
        echo "   ⚠️  未检测到 CUDA Toolkit，且当前 Git Bash 无管理员权限，无法自动安装。"
        echo "      以管理员身份重开 Git Bash 后重跑本脚本即可自动安装。"
    else
        echo "   未检测到 CUDA Toolkit，自动安装 CUDA 13.5（约 2.7GB，需 10 分钟左右，不会动显卡驱动）..."
        CUDA_INSTALLER="/tmp/cuda_13.5.0_windows_x86_64.exe"
        if curl -fL -C - --retry 3 -o "$CUDA_INSTALLER" \
            https://developer.download.nvidia.com/compute/cuda/13.5.0/local_installers/cuda_13.5.0_windows_x86_64.exe; then
            echo "   下载完成，静默安装中...（CUDA 13.x 静默语法为 -s 全组件，旧的 -s cuda 已废弃）"
            "$CUDA_INSTALLER" -s >/dev/null 2>&1 || true
            if CUDA_BIN="$(find_cuda_bin)"; then
                export PATH="$CUDA_BIN:$PATH"
                echo "   ✓ CUDA 安装完成: $CUDA_BIN"
            else
                echo "   ⚠️  CUDA 安装未成功，可手动安装: https://developer.nvidia.com/cuda-downloads"
            fi
            rm -f "$CUDA_INSTALLER"
        else
            echo "   ⚠️  CUDA 安装包下载失败，可手动安装: https://developer.nvidia.com/cuda-downloads"
        fi
    fi

    # ---- 工具链检查（CUDA 缺失时不再往下浪费流量；MSVC 体积过大不做自动安装）----
    TOOLCHAIN_MISSING=""
    if ! command -v nvcc >/dev/null 2>&1; then
        TOOLCHAIN_MISSING="CUDA Toolkit (nvcc)"
    elif ! command -v cl >/dev/null 2>&1; then
        VSWHERE="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
        if [ ! -x "$VSWHERE" ] || [ -z "$("$VSWHERE" -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>/dev/null)" ]; then
            TOOLCHAIN_MISSING="MSVC (Visual Studio C++ 生成工具)"
        fi
    fi
    if [ -n "$TOOLCHAIN_MISSING" ]; then
        echo "   ⚠️  缺少 $TOOLCHAIN_MISSING，跳过本地编译。装好后重跑："
        echo "      Visual Studio 2022+ (勾选 C++ 桌面开发) + CUDA Toolkit 13.x"
        echo "      或用 SKIP_SDCPP=1 跳过，由 start.sh 回退到 Docker。"
    else
        # 子 shell 中执行，避免 cd 影响主流程；失败不阻断安装
        # Windows 走 scripts/build_sdcpp_windows.cmd（固化 vcvars + VS 内嵌 CMake + Ninja
        # + NVCC_CCBIN + 新版选项名，规避 VS2026/CUDA13 .targets 与 CMake 4.3 的兼容问题）
        build_sdcpp() (
            if [ -d "$SDCPP_DIR/.git" ]; then
                # 上次已 clone，补齐子模块；网络失败但源码已就位（如镜像 tarball 手动解压）时继续
                cd "$SDCPP_DIR" || return 1
                if ! git submodule update --init --recursive; then
                    if [ -f ggml/CMakeLists.txt ]; then
                        echo "   (submodule 网络更新失败，检测到源码已就位，继续编译)"
                    else
                        return 1
                    fi
                fi
            else
                rm -rf "$SDCPP_DIR" &&
                git clone --recursive "${SDCPP_REPO:-https://github.com/leejet/stable-diffusion.cpp.git}" "$SDCPP_DIR" &&
                cd "$SDCPP_DIR"
            fi
            cd "$ROOT_DIR" || return 1
            _nvcc="$(command -v nvcc)" || { echo "   nvcc 不可用"; return 1; }
            _cuda_home="$(dirname "$_nvcc")"
            _cuda_home="${_cuda_home%/bin}"
            cmd //c "$(cygpath -w "$ROOT_DIR/scripts/build_sdcpp_windows.cmd")" \
                "$(cygpath -w "$ROOT_DIR/$SDCPP_DIR")" \
                "$(cygpath -w "$_cuda_home")" \
                "${SD_CUDA_ARCH:-89}"
        )
        if build_sdcpp; then
            echo "✅ SDCPP compiled (build/bin/sd-server.exe)"
        else
            echo "   ⚠️  SDCPP 获取/编译失败。常见原因与对策："
            echo "      - GitHub 直连不稳定：重跑，或加镜像前缀，如："
            echo "        SDCPP_REPO=https://ghfast.top/https://github.com/leejet/stable-diffusion.cpp.git sh scripts/install.sh"
            echo "      - 有代理时也可: git config --global http.proxy http://127.0.0.1:<端口>"
            echo "      - 或 SKIP_SDCPP=1 跳过，之后 docker build -t local-ai-gateway-sdcpp workers/sdcpp"
        fi
    fi
else
    git clone --recursive https://github.com/leejet/stable-diffusion.cpp.git "$SDCPP_DIR"
    cd "$SDCPP_DIR"
    mkdir -p build && cd build
    cmake .. \
        -DSD_CUDA=ON \
        -DCMAKE_CUDA_ARCHITECTURES="${SD_CUDA_ARCH:-all}" \
        -DSD_SERVER_BUILD_FRONTEND=OFF \
        -DCMAKE_BUILD_TYPE=Release
    make -j$(nproc)
    cd ../../../../..
    echo "✅ SDCPP compiled"
fi

# ---------- 完成 ----------
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║  ✅ 安装完成！                                    ║"
echo "║                                                  ║"
echo "║  下一步：                                         ║"
echo "║  1. 下载模型: ./scripts/download_models.sh        ║"
echo "║  2. 启动服务: ./scripts/start.sh                   ║"
echo "║  3. 测试:     ./scripts/test.sh                   ║"
echo "║  4. 查看 API: http://localhost:8000/docs          ║"
echo "╚══════════════════════════════════════════════════╝"
if [ "$IS_WINDOWS" -eq 1 ]; then
    echo ""
    echo "⚠️  Windows / Git Bash 注意事项："
    echo "  - 脚本不使用 sudo / apt / systemctl，Ollama / Redis 由 start.sh 自动拉起。"
    echo "  - SDCPP 编译产物为 sd-server.exe（build\\bin 下）；未编译成功时 start.sh 会回退到 Docker。"
fi
