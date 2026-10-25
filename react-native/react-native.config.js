module.exports = {
  dependency: {
    platforms: {
      android: {
        sourceDir: './android',
        packageImportPath: 'import app.pushify.reactnative.PushifyPurchasesPackage;',
        packageInstance: 'new PushifyPurchasesPackage()',
      },
      ios: {
        podspecPath: './PushifyPurchases.podspec',
      },
    },
  },
};
