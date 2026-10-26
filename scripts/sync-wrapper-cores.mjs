import { copyFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const copies = [
  ['ios/Sources/PushifySDK/PushifyPurchases.swift', 'flutter/ios/pushify_purchases/Sources/pushify_purchases/PushifyPurchasesCore.swift'],
  ['ios/Sources/PushifySDK/PushifyPurchases.swift', 'react-native/ios/PushifyPurchasesCore.swift'],
  ['android/pushify/src/main/kotlin/app/pushify/sdk/PushifyPurchases.kt', 'flutter/android/src/main/kotlin/app/pushify/sdk/PushifyPurchases.kt'],
  ['android/pushify/src/main/kotlin/app/pushify/sdk/PushifyPurchases.kt', 'react-native/android/src/main/java/app/pushify/sdk/PushifyPurchases.kt'],
];

for (const [source, target] of copies) await copyFile(resolve(root, source), resolve(root, target));
