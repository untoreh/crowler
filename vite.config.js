import { defineConfig } from "vite";
import { resolve } from "path";
import envCompatible from "vite-plugin-env-compatible";
import { injectHtml } from "vite-plugin-html";
import { viteCommonjs } from "@originjs/vite-plugin-commonjs";
import autoprefixer from "autoprefixer";
import legacy from "@vitejs/plugin-legacy";
import Unocss from "unocss/vite";
import presetIcons from "@unocss/preset-icons";

// https://vitejs.dev/config/
export default defineConfig({
  // entry: resolve(__dirname, "src/css/app.scss"),
  publicDir: "site",
  resolve: {
    alias: [
      {
        find: /^~/,
        replacement: "./",
      },
      {
        find: "@",
        replacement: resolve(__dirname, "src"),
      },
    ],
    extensions: [
      ".mjs",
      ".js",
      ".ts",
      ".jsx",
      ".tsx",
      ".json",
      ".vue",
      ".scss",
    ],
  },
  plugins: [
    viteCommonjs(),
    envCompatible(),
    injectHtml(),
    Unocss({
      presets: [
        presetIcons({
          /* options */
        }),
        // ...other presets
      ],
    }),
    // legacy({
    //   targets: ["defaults", "not IE 11"],
    // }),
  ],
  css: {
    postcss: {
      plugins: [autoprefixer()],
    },
  },
  build: {
    lib: {
      entry: "src/js/app.js",
      name: "app",
      fileName: "app"
    },
  },
});

// UnoCSS({
//   presets: [
//     presetIcons({
//       collections: {
//         mdi: () =>
//           import("@iconify-json/mdi/icons.json").then((i) => i.default),
//       },
//     }),
//   ],
// });
