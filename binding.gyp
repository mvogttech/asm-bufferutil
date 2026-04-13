{
  "targets": [
    {
      "target_name": "asm_bufferutil",
      "sources": [
        "src/ws_napi.c"
      ],
      "conditions": [
        ["OS=='linux' and target_arch=='x64'", {
          "actions": [
            {
              "action_name": "assemble",
              "inputs": ["src/ws_mask_asm.asm"],
              "outputs": ["<(INTERMEDIATE_DIR)/ws_mask_asm.o"],
              "action": [
                "nasm", "-f", "elf64",
                "-o", "<(INTERMEDIATE_DIR)/ws_mask_asm.o",
                "src/ws_mask_asm.asm"
              ]
            }
          ],
          "link_settings": {
            "libraries": [
              "<(INTERMEDIATE_DIR)/ws_mask_asm.o"
            ]
          }
        }]
      ],
      "include_dirs": [
        "<!@(node -p \"require('node-addon-api').include_dir || ''\" 2>/dev/null || echo '')"
      ],
      "cflags": ["-Wall", "-O2"],
      "defines": ["NAPI_VERSION=8"]
    }
  ]
}
