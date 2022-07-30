const autoprefixer = require("autoprefixer");
const path = require("path");
// const UnoCSS = require("unocss/webpack").default;

module.exports = {
  // for unocss, https://stackoverflow.com/questions/64557638/how-to-polyfill-node-core-modules-in-webpack-5
  // target: "node",
  context: path.resolve(__dirname, "src"),
  entry: ["./css/app.scss", "./js/app.js"],
  // plugins: [UnoCSS({})],
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
                plugins: [autoprefixer()],
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
