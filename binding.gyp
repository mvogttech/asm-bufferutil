{
  "targets": [
    {
      "target_name": "asm_bufferutil",
      "sources": [
        "ws_napi.c",
        "ws_sha1_ni.c"
      ],
      "conditions": [
        ["OS=='linux' and target_arch=='x64'", {
          "actions": [
            {
              "action_name": "assemble_cpu",
              "inputs":  ["ws_cpu.asm"],
              "outputs": ["<(INTERMEDIATE_DIR)/ws_cpu.o"],
              "action": ["nasm", "-f", "elf64",
                         "-o", "<(INTERMEDIATE_DIR)/ws_cpu.o",
                         "ws_cpu.asm"]
            },
            {
              "action_name": "assemble_mask",
              "inputs":  ["ws_mask_asm.asm"],
              "outputs": ["<(INTERMEDIATE_DIR)/ws_mask_asm.o"],
              "action": ["nasm", "-f", "elf64",
                         "-o", "<(INTERMEDIATE_DIR)/ws_mask_asm.o",
                         "ws_mask_asm.asm"]
            },
            {
              "action_name": "assemble_base64",
              "inputs":  ["ws_base64_asm.asm"],
              "outputs": ["<(INTERMEDIATE_DIR)/ws_base64_asm.o"],
              "action": ["nasm", "-f", "elf64",
                         "-o", "<(INTERMEDIATE_DIR)/ws_base64_asm.o",
                         "ws_base64_asm.asm"]
            },
            {
              "action_name": "assemble_crc32",
              "inputs":  ["ws_crc32_asm.asm"],
              "outputs": ["<(INTERMEDIATE_DIR)/ws_crc32_asm.o"],
              "action": ["nasm", "-f", "elf64",
                         "-o", "<(INTERMEDIATE_DIR)/ws_crc32_asm.o",
                         "ws_crc32_asm.asm"]
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
      "defines": ["NAPI_VERSION=8"]
    }
  ]
}
