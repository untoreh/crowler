const autoprefixer = require("autoprefixer");
const path = require("path");

module.exports = [
  {
    context: path.resolve(__dirname, "src"),
    entry: ["./css/app.scss", "./js/app.js"],
    mode: "production",
    devServer: {
      static: "site/",
      // see https://stackoverflow.com/questions/59247647/webpack-dev-server-not-recompiling-js-files-and-scss-files
      hot: true,
    },
    watchOptions: {
        aggregateTimeout: 300,
        poll: true,
        ignored: /node_modules/
    },
    // devtool: false,
    // mode: "development",
    output: {
      // This is necessary for webpack to compile
      filename: "bundle.js",
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
            { loader: "extract-loader" },
            { loader: "css-loader" },
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
      ],
    },
  },
];
