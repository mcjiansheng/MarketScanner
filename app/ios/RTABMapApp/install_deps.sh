#!/bin/bash

set -euxo pipefail

# Tested on Apple Silicon Mac, with cmake 4.0.2, XCode 16.3.

mkdir -p Libraries
cd Libraries
pwd=$(pwd)
prefix=$pwd
sysroot=iphoneos
#sysroot=iphonesimulator

clone_with_retry()
{
  local destination=$1
  shift
  if [ -z "$destination" ] || [[ "$destination" == .* ]] || [[ "$destination" == */* ]]
  then
    echo "Unsafe dependency clone destination: $destination" >&2
    return 2
  fi
  local attempt temporary
  for attempt in 1 2 3
  do
    temporary=$(mktemp -d "$pwd/.clone-${destination}.XXXXXX")
    if git clone "$@" "$temporary/repository"
    then
      mv "$temporary/repository" "$destination"
      rmdir "$temporary"
      return 0
    fi
    rm -rf "$temporary"
    if [ "$attempt" -lt 3 ]
    then
      sleep $((attempt * 5))
    fi
  done
  echo "Failed to clone $destination after 3 attempts" >&2
  return 1
}

download_with_retry()
{
  local url=$1
  local output=$2
  local temporary="${output}.partial"
  curl --fail --location --retry 3 --retry-all-errors --retry-delay 5 \
    "$url" -o "$temporary"
  mv -f "$temporary" "$output"
}

# openmp
# based on https://github.com/Homebrew/homebrew-core/blob/HEAD/Formula/libomp.rb
#curl -L https://github.com/llvm/llvm-project/releases/download/llvmorg-11.1.0/openmp-11.1.0.src.tar.xz -o openmp-11.1.0.src.tar.xz
#tar -xzf openmp-11.1.0.src.tar.xz
#cd openmp-11.1.0.src
#curl -L https://raw.githubusercontent.com/Homebrew/formula-patches/7e2ee1d7/libomp/arm.patch -o arm.patch
#patch -p1 < arm.patch
#mkdir build
#cd build
#cmake -G Xcode -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=$sysroot -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 -DCMAKE_INSTALL_PREFIX=$prefix -DLIBOMP_INSTALL_ALIASES=OFF -DLIBOMP_ENABLE_SHARED=OFF ..
#cmake --build . --config Release -- CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED="NO" CODE_SIGN_ENTITLEMENTS=""  CODE_SIGNING_ALLOWED="NO"
#cp runtime/src/Release-iphoneos/libomp.a runtime/src/.
#cmake --build . --config Release --target install -- CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED="NO" CODE_SIGN_ENTITLEMENTS=""  CODE_SIGNING_ALLOWED="NO"

# Boost
if [ ! -e $prefix/include/boost ]
then
if [ ! -e boost-1.88.0 ]
then
  echo "wget boost..."
  download_with_retry https://github.com/boostorg/boost/releases/download/boost-1.88.0/boost-1.88.0-cmake.tar.gz boost-1.88.0-cmake.tar.gz
  tar -xzf boost-1.88.0-cmake.tar.gz
fi
cd boost-1.88.0
mkdir -p build
cd build
cmake -G Xcode -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT=$sysroot -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 -DCMAKE_INSTALL_PREFIX=$prefix -DBOOST_INCOMPATIBLE_LIBRARIES="process;context;coroutine;fiber;fiber_numa;log_setup;log;cobalt" -DBOOST_IOSTREAMS_ENABLE_ZLIB=OFF -DBOOST_IOSTREAMS_ENABLE_BZIP2=OFF ..
cmake --build . --config Release
cmake --build . --config Release --target install
cd $pwd
#rm -r boost-1.88.0-cmake.tar.gz boost-1.88.0
fi

# eigen
if [ ! -e $prefix/include/eigen3 ]
then
if [ ! -e eigen-3.4.0 ]
then
  echo "wget eigen..."
  download_with_retry https://gitlab.com/libeigen/eigen/-/archive/3.4.0/eigen-3.4.0.tar.gz 3.4.0.tar.gz
  tar -xzf 3.4.0.tar.gz
fi
cd eigen-3.4.0
mkdir -p build
cd build
cmake -G Xcode -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT=$sysroot -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 -DCMAKE_INSTALL_PREFIX=$prefix ..
cmake --build . --config Release
cmake --build . --config Release --target install
cd $pwd
#rm -r 3.4.0.tar.gz eigen-3.4.0
fi

# lz4 (required by flann)
if [ ! -e $prefix/include/lz4.h ]
then
if [ ! -e lz4 ]
then
  echo "wget lz4..."
  clone_with_retry lz4 --branch v1.10.0 https://github.com/lz4/lz4.git
fi
cd lz4
if [ ! -e LZ4Config.cmake.in ]
then
  download_with_retry https://gist.githubusercontent.com/matlabbe/abd0242305c29495bbba26065269daf2/raw/ad0b1865c02e61449f58358fdc4ddbed3cb5fb87/LZ4Config.cmake.in LZ4Config.cmake.in
fi
if [ ! -e CMakeLists.txt ]
then
  download_with_retry https://gist.githubusercontent.com/matlabbe/abd0242305c29495bbba26065269daf2/raw/ad0b1865c02e61449f58358fdc4ddbed3cb5fb87/CMakeLists.txt CMakeLists.txt
fi
mkdir -p build
cd build
cmake -G Xcode -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT=$sysroot -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 -DCMAKE_INSTALL_PREFIX=$prefix ..
cmake --build . --config Release -- CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED="NO" CODE_SIGN_ENTITLEMENTS=""  CODE_SIGNING_ALLOWED="NO"
cmake --build . --config Release --target install -- CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED="NO" CODE_SIGN_ENTITLEMENTS=""  CODE_SIGNING_ALLOWED="NO"
cd $pwd
#rm -r lz4
fi

# FLANN
if [ ! -e $prefix/include/flann ]
then
if [ ! -e flann ]
then
  echo "wget flann..."
  clone_with_retry flann --branch 1.9.2 https://github.com/flann-lib/flann.git
fi
cd flann
if [ ! -e flann_ios_lz4.patch ]
then
  download_with_retry https://gist.githubusercontent.com/matlabbe/c858ba36fb85d5e44d8667dfb3543e12/raw/2586a356dec2b11440ec3c1bb113e709e1266d97/flann_ios_lz4.patch flann_ios_lz4.patch
  git apply flann_ios_lz4.patch
fi
mkdir -p build
cd build
cmake -G Xcode -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT=$sysroot -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 -DCMAKE_INSTALL_PREFIX=$prefix -DBUILD_PYTHON_BINDINGS=OFF -DBUILD_MATLAB_BINDINGS=OFF -DBUILD_C_BINDINGS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_TESTS=OFF -DBUILD_DOC=OFF -DUSE_OPENMP=OFF -DLZ4_DIR=$prefix/lib/lz4  ..
cmake --build . --config Release -- CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED="NO" CODE_SIGN_ENTITLEMENTS=""  CODE_SIGNING_ALLOWED="NO"
cmake --build . --config Release --target install -- CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED="NO" CODE_SIGN_ENTITLEMENTS=""  CODE_SIGNING_ALLOWED="NO"
cd $pwd
#rm -r flann
fi

# GTSAM
if [ ! -e $prefix/include/gtsam ]
then
if [ ! -e gtsam ]
then
  clone_with_retry gtsam --branch 4.2 --depth 1 https://github.com/borglab/gtsam.git
fi
cd gtsam
# patch
if [ ! -e gtsam_4_2_ios.patch ]
then
  download_with_retry https://gist.githubusercontent.com/matlabbe/76d658dddb841b3355ae3a6e32850cd8/raw/e7355348c2d536ec50f41effa775ed251ae4e045/gtsam_4_2_ios.patch gtsam_4_2_ios.patch
  git apply gtsam_4_2_ios.patch
fi
mkdir -p build
cd build
cmake -G Xcode -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT=$sysroot -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=17 -DGTSAM_CXX_STANDARD=17 -DCMAKE_CXX_STANDARD_REQUIRED=ON -DCMAKE_CXX_EXTENSIONS=OFF -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 -DCMAKE_INSTALL_PREFIX=$prefix -DMETIS_SHARED=OFF -DGTSAM_BUILD_STATIC_LIBRARY=ON -DGTSAM_BUILD_TESTS=OFF -DGTSAM_BUILD_EXAMPLES_ALWAYS=OFF -DGTSAM_USE_SYSTEM_EIGEN=ON -DGTSAM_WRAP_SERIALIZATION=OFF -DGTSAM_BUILD_WRAP=OFF -DGTSAM_INSTALL_CPPUNITLITE=OFF -DCMAKE_FIND_ROOT_PATH=$prefix ..
cmake --build . --config Release -- CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED="NO" CODE_SIGN_ENTITLEMENTS=""  CODE_SIGNING_ALLOWED="NO"
cmake --build . --config Release --target install -- CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED="NO" CODE_SIGN_ENTITLEMENTS=""  CODE_SIGNING_ALLOWED="NO"
cd $pwd
#rm -rf gtsam
fi

# suitesparse (dependency of g2o)
if [ ! -e $prefix/include/suitesparse/SuiteSparse_config.h ]
then
if [ ! -e SuiteSparse ]
then
  clone_with_retry SuiteSparse --branch v7.6.1 https://github.com/DrTimothyAldenDavis/SuiteSparse.git
fi
cd SuiteSparse
mkdir -p build
cd build
cmake -G Xcode -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT=$sysroot -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 -DCMAKE_INSTALL_PREFIX=$prefix -DCMAKE_FIND_ROOT_PATH=$prefix -DSUITESPARSE_USE_OPENMP=OFF -DSUITESPARSE_ENABLE_PROJECTS="cholmod;cxsparse;spqr"  ..
cmake --build . --config Release -- CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED="NO" CODE_SIGN_ENTITLEMENTS=""  CODE_SIGNING_ALLOWED="NO"
cmake --build . --config Release --target install -- CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED="NO" CODE_SIGN_ENTITLEMENTS=""  CODE_SIGNING_ALLOWED="NO"
cd $pwd
fi

# g2o
if [ ! -e $prefix/include/g2o ]
then
if [ ! -e g2o ]
then
  clone_with_retry g2o --branch 20241228_git https://github.com/RainerKuemmerle/g2o.git
fi
cd g2o
# patch
if [ ! -e g2o_20241228_ios.patch ]
then
ls
  download_with_retry https://gist.githubusercontent.com/matlabbe/b9ccfeae8f0744b275cab23510872680/raw/6fe2ffe5ba8fba59171adbd2f38f9c3999c61f75/g2o_20241228_ios.patch g2o_20241228_ios.patch
  git apply g2o_20241228_ios.patch
fi
mkdir -p build
cd build
cmake -G Xcode -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT=$sysroot -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release "-DCMAKE_CXX_FLAGS=-include TargetConditionals.h" -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 -DCMAKE_INSTALL_PREFIX=$prefix -DBUILD_LGPL_SHARED_LIBS=OFF -DG2O_BUILD_APPS=OFF -DG2O_BUILD_EXAMPLES=OFF -DCMAKE_FIND_ROOT_PATH=$prefix ..
cmake --build . --config Release -- CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED="NO" CODE_SIGN_ENTITLEMENTS=""  CODE_SIGNING_ALLOWED="NO"
cmake --build . --config Release --target install -- CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED="NO" CODE_SIGN_ENTITLEMENTS=""  CODE_SIGNING_ALLOWED="NO"
cd $pwd
#rm -rf g2o
fi

# VTK
if [ ! -e $prefix/lib/vtk.framework ]
then
if [ ! -e VTK ]
then
  clone_with_retry VTK --branch v9.5.0.rc1 --depth 1 https://github.com/Kitware/VTK.git
  cd VTK
else
  cd VTK
fi
mkdir -p build
cd build
cmake -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_FRAMEWORK_INSTALL_PREFIX=$prefix/lib -DIOS_DEPLOYMENT_TARGET=12.0 -DIOS_DEVICE_ARCHITECTURES="arm64" -DIOS_SIMULATOR_ARCHITECTURES="" -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF -DVTK_IOS_BUILD=ON -DModule_vtkFiltersModeling=ON ..
# For iphonesimulator: add -DIOS_DEVICE_ARCHITECTURES=""
cmake --build . --config Release
cd $pwd
#rm -rf VTK
fi



# PCL
if [ ! -e $prefix/include/pcl-1.15 ]
then
if [ ! -e pcl ]
then
  clone_with_retry pcl --branch pcl-1.15.0 --depth 1 https://github.com/PointCloudLibrary/pcl.git
  cd pcl
else
  cd pcl
fi
# patch
if [ ! -e pcl_1_15_0_ios.patch ]
then
  download_with_retry https://gist.githubusercontent.com/matlabbe/f3ba9366eb91e1b855dadd2ddce5746d/raw/7231688d7fb9e86df72ca7c5f355d6b9727205d5/pcl_1_15_0_ios.patch pcl_1_15_0_ios.patch
  git apply pcl_1_15_0_ios.patch
fi
mkdir -p build
cd build
cmake -G Xcode -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT=$sysroot -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 -DCMAKE_INSTALL_PREFIX=$prefix -DBUILD_apps=OFF -DBUILD_examples=OFF -DBUILD_tools=OFF -DBUILD_visualization=OFF -DBUILD_tracking=OFF -DBUILD_people=OFF -DBUILD_recognition=OFF -DBUILD_global_tests=OFF -DWITH_QT=OFF -DWITH_OPENGL=OFF -DWITH_OPENMP=OFF -DWITH_VTK=ON -DPCL_FLANN_REQUIRED_TYPE=STATIC -DPCL_SHARED_LIBS=OFF -DPCL_ENABLE_SSE=OFF -DCMAKE_FIND_ROOT_PATH=$prefix ..
cmake --build . --config Release
cmake --build . --config Release --target install
cd $pwd
#rm -rf pcl
fi

# OpenCV
if [ ! -e $prefix/include/opencv4 ]
then
if [ ! -e opencv_contrib ]
then
  clone_with_retry opencv_contrib --branch 4.11.0 https://github.com/opencv/opencv_contrib.git
fi
cd $pwd
if [ ! -e opencv ]
then
  clone_with_retry opencv --branch 4.11.0 https://github.com/opencv/opencv.git
fi
cd opencv
mkdir -p build
cd build
cmake -G Xcode -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT=$sysroot -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 -DCMAKE_INSTALL_PREFIX=$prefix -DOPENCV_EXTRA_MODULES_PATH=$prefix/opencv_contrib/modules -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF -DWITH_CUDA=OFF -DWITH_WEBP=OFF -DWITH_OPENEXR=OFF -DBUILD_opencv_apps=OFF -DBUILD_opencv_xobjdetect=OFF -DBUILD_opencv_stereo=OFF -DOPENCV_ENABLE_NONFREE=ON ..
cmake --build . --config Release
cmake --build . --config Release --target install
cd $pwd
#rm -rf opencv opencv_contrib
fi

# LAZ (dependency for liblas)
# LAS
if [ ! -e $prefix/include/laszip ]
then
if [ ! -e LASzip ]
then
  clone_with_retry LASzip --branch 2.0.1 https://github.com/LASzip/LASzip.git
fi
cd LASzip
sed -i '' 's/cmake_minimum_required(VERSION 2.6.0)/cmake_minimum_required(VERSION 3.5)/g' CMakeLists.txt
sed -i '' 's/add_subdirectory(tools)/#add_subdirectory(tools)/g' CMakeLists.txt
mkdir -p build
cd build
cmake -G Xcode -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT=$sysroot -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 -DCMAKE_INSTALL_PREFIX=$prefix -DCMAKE_FIND_ROOT_PATH=$prefix -DBUILD_STATIC=ON ..
cmake --build . --config Release -- CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED="NO" CODE_SIGN_ENTITLEMENTS=""  CODE_SIGNING_ALLOWED="NO"
cmake --build . --config Release --target install -- CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED="NO" CODE_SIGN_ENTITLEMENTS=""  CODE_SIGNING_ALLOWED="NO"
cd $pwd
fi

# LAS
if [ ! -e $prefix/include/liblas ]
then
if [ ! -e libLAS ]
then
  clone_with_retry libLAS --filter=blob:none --no-checkout https://github.com/libLAS/libLAS.git
  git -C libLAS checkout --detach 33097f17e27b853ac7b9651025a70354ffb10cfc
fi
cd libLAS
sed -i '' 's/cmake_minimum_required(VERSION 2.8.11)/cmake_minimum_required(VERSION 3.5)/g' CMakeLists.txt
sed -i '' 's/SHARED/STATIC/g' src/CMakeLists.txt
mkdir -p build
cd build
cmake -G Xcode -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT=$sysroot -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 -DCMAKE_INSTALL_PREFIX=$prefix -DCMAKE_FIND_ROOT_PATH=$prefix -DWITH_UTILITIES=OFF -DWITH_TESTS=OFF -DWITH_GEOTIFF=OFF -DWITH_LASZIP=ON -DWITH_STATIC_LASZIP=ON ..
cmake --build . --config Release -- CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED="NO" CODE_SIGN_ENTITLEMENTS=""  CODE_SIGNING_ALLOWED="NO"
cmake --build . --config Release --target install -- CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED="NO" CODE_SIGN_ENTITLEMENTS=""  CODE_SIGNING_ALLOWED="NO"
cd $pwd
fi

mkdir -p rtabmap
cd rtabmap
cmake -DANDROID_PREBUILD=ON ../../../../..
cmake --build . --config Release
mkdir -p ios
cd ios
cmake -G Xcode -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT=$sysroot -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 -DCMAKE_INSTALL_PREFIX=$prefix -DCMAKE_FIND_ROOT_PATH=$prefix -DWITH_QT=OFF -DBUILD_APP=OFF -DBUILD_TOOLS=OFF -DWITH_TORO=OFF -DWITH_VERTIGO=OFF -DWITH_MADGWICK=OFF -DWITH_ORB_OCTREE=ON  -DBUILD_EXAMPLES=OFF -DWITH_LIBLAS=ON -DWITH_OPENGV=OFF ../../../../../..
cmake --build . --config Release
cmake --build . --config Release --target install
