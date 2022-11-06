const autoprefixer = require("autoprefixer");
const path = require("path");
const process = require("process")
// const UnoCSS = require("unocss/webpack").default;
const CriticalCssPlugin = require('critical-css-webpack-plugin')

module.exports = {
  // for unocss, https://stackoverflow.com/questions/64557638/how-to-polyfill-node-core-modules-in-webpack-5
  // target: "node",
  context: path.resolve(__dirname, "src"),
  entry: ["./css/app.scss", "./js/app.js"],
  // plugins: [UnoCSS({})],
  plugins: [new CriticalCssPlugin(
    {
      inline: false,
      base: "./site",
      src: "http://wsl:5050",
      dimensions: [
        {
          width: 1200,
        },
        {
          width: 600,
        },
        {
          width: 400,
        },
        {
          width: 200,
        },
      ],
      target: {
        css: "../dist/bundle-crit.css",
        uncritical: '../dist/bundle.css',
      },
      // extract: true,
      ignore: {
        atrule: ['@font-face'],
        rule: [/\.i-mdi-.*/, /\.flag/]
      },
      rebase: asset => { // inlined styles requires specifing absolute assets path (since assets with name only use the path relative to style source link)
        let devpath = "dev/"
        let abspath = asset.absolutePath
        let nametrail = `${process.env.CONFIG_NAME}/`
        if (nametrail && nametrail != devpath && abspath.includes(devpath)) {
          if (asset.pathname) {
            return `${abspath.replace(devpath, nametrail)}`
          } else {
            return asset.url
          }
        }
      },
    }
  )
  ],
  mode: "production",
  devServer: {
    static: {
      directory: "site/",
      staticOptions: {
        extensions: ["html"],
      },
    },
    // see https://stackoverflow.com/questions/59247647/webpack-dev-server-not-recompiling-js-files-and-scss-files
    hot: true,
    setupMiddlewares: (middlewares, devServer) => {
      if (!devServer) {
        throw new Error("webpack-dev-server is not defined");
      }

      // middlewares.unshift({
      //     name: "ok",
      //     middleware: (req, res) => {
      //     console.log(req["_parsedUrl"].pathname.split(".").pop())
      //     res.send("Done")
      // }});

      return middlewares;
    },
  },
  watchOptions: {
    aggregateTimeout: 300,
    poll: true,
    ignored: /node_modules/,
  },
  // devtool: false,
  // mode: "development",
  output: {
    // This is necessary for webpack to compile
    filename: "bundle.js",
    // Needed to resolve url used in css correctly
    publicPath: "",
  },
  module: {
    rules: [
      {
        test: /\.scss$/,
        use: [
          {
            loader: "file-loader",
            options: {
              name: "bundle.css",
            },
          },
          {
            loader: "extract-loader",
          },
          {
            loader: "css-loader",
            options: {
              // https://github.com/peerigon/extract-loader/issues/102#issuecomment-895558537
              esModule: false,
            },
          },
          {
            loader: "postcss-loader",
            options: {
              postcssOptions: {
                plugins: [autoprefixer(),
                ],
              },
            },
          },
          {
            loader: "sass-loader",
            options: {
              // Prefer Dart Sass
              implementation: require("sass"),

              // See https://github.com/webpack-contrib/sass-loader/issues/804
              webpackImporter: false,
              sassOptions: {
                includePaths: ["./node_modules"],
              },
            },
          },
        ],
      },
      {
        test: /\.js$/,
        loader: "babel-loader",
        options: {
          presets: ["@babel/preset-env"],
        },
      },
      {
        test: /\.png$/,
        loader: "file-loader",
      },
      {
        test: /\.(png|svg|jpe?g|gif)$/,
        include: /images/,
        use: [
          {
            loader: "file-loader",
            options: {
              name: "[name].[ext]",
              outputPath: "images/",
              publicPath: "images/",
            },
          },
        ],
      },
    ],
  },
};
