#!/usr/bin/env bash

input_dir="$1"

convert_image_to_jxl() {
    local image_file="$1"
    local filename="${image_file%.*}"
    local jxl_file="${filename}.jxl"
    local mime_type=$(file -b --mime-type "$1")

    if [[ $mime_type == "image/jpeg" ]]; then
        cjxl --quiet -j 1 "$image_file" "$jxl_file" && rm "$image_file"
    elif [[ $mime_type == "image/png" ]]; then
        cjxl --quiet -d 1 "$image_file" "$jxl_file" && rm "$image_file"
    else
        echo "Skipping unsupported mime type: $mime_type"
    fi
}

export -f convert_image_to_jxl

echo "Converting images to JXLs..."
find "$input_dir" -type f -iname "*.jpg" -or -iname "*.jpeg" -or -iname "*.png" | xargs -P $(nproc) -I {} bash -c 'convert_image_to_jxl "{}"'

echo "Image to JXL conversion completed!"
