FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04

RUN apt-get update && apt-get install -y \
    git \
    cmake \
    build-essential \
    libcurl4-openssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN git clone --recursive https://github.com/leejet/stable-diffusion.cpp.git \
    && cd stable-diffusion.cpp \
    && mkdir build && cd build \
    && cmake .. \
        -DSD_CUDA=ON \
        -DSD_CUDA_ARCH=all \
        -DSDCPP_WEBUI=OFF \
        -DSDCPP_RESTAPI=ON \
        -DCMAKE_BUILD_TYPE=Release \
    && make -j$(nproc)

ENV MODELS_PATH=/models
ENV SD_CUDA=1

EXPOSE 8080

CMD ["/app/stable-diffusion.cpp/build/sd-rest-api", \
     "--host", "0.0.0.0", \
     "--port", "8080", \
     "--models-path", "/models", \
     "--cuda", \
     "--threads", "8"]
