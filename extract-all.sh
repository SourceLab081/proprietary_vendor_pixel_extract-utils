#!/bin/bash

if [ -z "$ANDROID_BUILD_TOP" ]; then
  echo "Error: ANDROID_BUILD_TOP is not set."
  exit 1
fi

ANDROID_ROOT="$ANDROID_BUILD_TOP"
HOST="${HOST:-$(uname -s | tr '[:upper:]' '[:lower:]')}"

EXTRACT_TMP_DIR=$(mktemp -d)
PHONE_DUMP=$(mktemp -d)
TABLET_DUMP=$(mktemp -d)

cleanup() {
  rm -rf "$EXTRACT_TMP_DIR" "$PHONE_DUMP" "$TABLET_DUMP"
}
trap cleanup EXIT

extract_img_data() {
  local image_file="$1"
  local out_dir="$2"
  local log_file="$EXTRACT_TMP_DIR/debugfs.log"

  mkdir -p "$out_dir"

  debugfs -R 'ls -p' "$image_file" 2>/dev/null | cut -d '/' -f6 | while read -r entry; do
    if ! debugfs -R "rdump \"$entry\" \"$out_dir\"" "$image_file" >>"$log_file" 2>&1; then
      echo "[-] Failed to extract data from '$image_file'"
      exit 1
    fi
  done

  local symlink_err="rdump: Attempt to read block from filesystem resulted in short read while reading symlink"
  if grep -Fq "$symlink_err" "$log_file"; then
    echo "[-] Symlinks were not properly processed from $image_file"
    echo "[!] Your debugfs version may be incompatible."
    exit 1
  fi
}

setup_android_env() {
  if [[ ! -d "$ANDROID_ROOT" ]]; then
    echo "Error: ANDROID_ROOT is not a valid directory: $ANDROID_ROOT"
    exit 1
  fi

  local bin_dir="${ANDROID_ROOT}/prebuilts/extract-tools/${HOST}-x86/bin"
  export OTA_EXTRACTOR="${bin_dir}/ota_extractor"
}

extract_and_prepare() {
  local zip_file="$1"
  local dump_dir="$2"

  echo "Preparing dump directory: $dump_dir"
  rm -rf "$dump_dir"
  mkdir -p "$dump_dir"

  echo "Unzipping $zip_file ..."
  if ! unzip -qo "$zip_file" -d "$dump_dir"; then
    echo "Error: Failed to unzip $zip_file"
    return 1
  fi

  if [[ -f "$dump_dir/payload.bin" ]]; then
    echo "Extracting A/B OTA payload partitions..."
    for partition in product system system_ext; do
      "$OTA_EXTRACTOR" --payload "$dump_dir/payload.bin" --output_dir "$dump_dir" --partitions "$partition" &
    done
    wait
  fi

  for partition in product system system_ext; do
    local dat_br="$dump_dir/${partition}.new.dat.br"
    local dat="$dump_dir/${partition}.new.dat"
    local transfer_list="$dump_dir/${partition}.transfer.list"
    local img="$dump_dir/${partition}.img"
    local out_dir="$dump_dir/$partition"

    [[ -f "$dat_br" ]] && { echo "Decompressing $dat_br ..."; brotli -d "$dat_br" && rm -f "$dat_br"; }
    if [[ -f "$dat" && -f "$transfer_list" ]]; then
      echo "Converting $dat to $img ..."
      if ! python3 "$ANDROID_ROOT/tools/extract-utils/sdat2img.py" "$transfer_list" "$dat" "$img"; then
        echo "Warning: sdat2img.py failed for $partition"
      fi
      rm -f "$dat" "$transfer_list"
    fi

    if [[ -f "$img" ]]; then
      mkdir -p "$out_dir"
      if declare -f extract_img_data >/dev/null; then
        extract_img_data "$img" "$out_dir"
      else
        echo "Notice: extract_img_data not defined, skipping image extraction."
      fi
      rm -f "$img"
    fi
  done

  echo "Extraction and preparation of $zip_file complete."
}


# Parse arguments
phone_zip=""
tablet_zip=""
while (( $# )); do
  case "$1" in
    --phone) phone_zip="$2"; shift 2 ;;
    --tablet) tablet_zip="$2"; shift 2 ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 --phone <phone_zip> --tablet <tablet_zip>"
      exit 1
      ;;
  esac
done

if [[ -z "$phone_zip" || -z "$tablet_zip" ]]; then
  echo "Error: Both --phone and --tablet must be provided."
  exit 1
fi
if [[ ! -f "$phone_zip" ]]; then
  echo "Error: Phone zip file not found: $phone_zip"
  exit 1
fi
if [[ ! -f "$tablet_zip" ]]; then
  echo "Error: Tablet zip file not found: $tablet_zip"
  exit 1
fi

setup_android_env

phone_base_name=$(basename "$phone_zip" | sed 's/-[^-]*$//')
tablet_base_name=$(basename "$tablet_zip" | sed 's/-[^-]*$//')

extract_and_prepare "$phone_zip" "$PHONE_DUMP" || { echo "Phone zip extraction failed"; exit 1; }
extract_and_prepare "$tablet_zip" "$TABLET_DUMP" || { echo "Tablet zip extraction failed"; exit 1; }

repos=(
  "clocks"
  "gms"
  "gsans"
  "launcher"
  "sounds"
  "themepicker"
)

for repo in "${repos[@]}"; do
  if [[ -d "$repo" ]]; then
    echo "Processing repo: $repo"
    pushd "$repo" > /dev/null || { echo "Failed to enter repo: $repo"; continue; }

    if [[ ! -x ./extract-files.sh ]]; then
      echo "Error: extract-files.sh not found or not executable in $repo"
      popd > /dev/null
      continue
    fi

    ./extract-files.sh "$PHONE_DUMP"
    if [[ "$repo" == "launcher" ]]; then
      ./extract-files.sh --only-tablet "$TABLET_DUMP"
    fi

    for file in proprietary-files*.txt; do
      [[ -f "$file" ]] || continue
      if [[ "$file" == *"tablet"* ]]; then
        sed -i "1c# Extracted from ${tablet_base_name}" "$file"
      else
        sed -i "1c# Extracted from ${phone_base_name}" "$file"
      fi
    done

    git add .
    if [[ "$repo" == "launcher" ]]; then
      git commit -m "${repo}: Update from ${phone_base_name} and ${tablet_base_name}" || echo "Nothing to commit in $repo"
    else
      git commit -m "${repo}: Update from ${phone_base_name}" || echo "Nothing to commit in $repo"
    fi

    popd > /dev/null
  else
    echo "Repo directory $repo does not exist, skipping."
  fi
done
