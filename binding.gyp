{
  "targets": [
    {
      "target_name": "asm_bufferutil",
      "sources": [
        "src/ws_napi.c",
        "src/ws_sha1_ni.c"
      ],
      "conditions": [
        ["OS!='linux' or target_arch!='x64'", {
          "sources": ["src/ws_fallback.c"]
        }],
        ["OS=='win'", {
          "msvs_settings": {
            "VCCLCompilerTool": {
              "AdditionalOptions": ["/arch:AVX2"]
            }
          }
        }],
        ["OS=='linux' and target_arch=='x64'", {
          "actions": [
            {
              "action_name": "assemble_cpu",
              "inputs":  ["src/ws_cpu.asm"],
              "outputs": ["<(INTERMEDIATE_DIR)/ws_cpu.o"],
              "action": ["nasm", "-f", "elf64",
                         "-o", "<(INTERMEDIATE_DIR)/ws_cpu.o",
                         "src/ws_cpu.asm"]
            },
            {
              "action_name": "assemble_mask",
              "inputs":  ["src/ws_mask_asm.asm"],
              "outputs": ["<(INTERMEDIATE_DIR)/ws_mask_asm.o"],
              "action": ["nasm", "-f", "elf64",
                         "-o", "<(INTERMEDIATE_DIR)/ws_mask_asm.o",
                         "src/ws_mask_asm.asm"]
            },
            {
              "action_name": "assemble_base64",
              "inputs":  ["src/ws_base64_asm.asm"],
              "outputs": ["<(INTERMEDIATE_DIR)/ws_base64_asm.o"],
              "action": ["nasm", "-f", "elf64",
                         "-o", "<(INTERMEDIATE_DIR)/ws_base64_asm.o",
                         "src/ws_base64_asm.asm"]
            },
            {
              "action_name": "assemble_crc32",
              "inputs":  ["src/ws_crc32_asm.asm"],
              "outputs": ["<(INTERMEDIATE_DIR)/ws_crc32_asm.o"],
              "action": ["nasm", "-f", "elf64",
                         "-o", "<(INTERMEDIATE_DIR)/ws_crc32_asm.o",
                         "src/ws_crc32_asm.asm"]
            }
          ],
          "link_settings": {
            "libraries": [
              "<(INTERMEDIATE_DIR)/ws_cpu.o",
              "<(INTERMEDIATE_DIR)/ws_mask_asm.o",
              "<(INTERMEDIATE_DIR)/ws_base64_asm.o",
              "<(INTERMEDIATE_DIR)/ws_crc32_asm.o"
            ]
          }
        }]
      ],
      "cflags": ["-Wall", "-O2", "-msha", "-mgfni"],
      "defines": ["NAPI_VERSION=9"]
    }
  ]
}
