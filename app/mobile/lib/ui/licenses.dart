import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../executors/voicevox_tts.dart';

/// ライセンスと出典。
///
/// - pub.dev のパッケージと Flutter 本体のライセンスは、Flutter が自動で集めて
///   [showLicensePage] に出す（ここでは足さない）
/// - pub.dev 以外でアプリに入っているもの（VOICEVOX の部品・Kotlin の標準ライブラリ）と、
///   出典の表示が求められているデータを [registerExtraLicenses] で足す
/// - 一覧は docs/attribution.md と著作物利用シートに合わせる

/// 設定画面の「出典」に出す文。ライセンスで出典の表示が求められているもの。
const dataAttributions = <String>[
  '地図データ（ランドマークの位置・形、横断歩道・信号）：© OpenStreetMap contributors（ODbL 1.0）',
  '町丁目名：「位置参照情報」（国土交通省）を加工して作成',
  '気象警報：出典 気象庁ホームページ（防災情報XML）。種類とレベルを取り出し、文に加工して作成',
  '富山城址公園の解説：富山市オープンデータ「インフォマップとやま 観光情報マップ 文化財情報」（CC BY）をもとに作成',
  'ランドマークの解説：富山県・富山市・各施設の公式サイトなどの事実をもとに作成（一覧はリポジトリの docs/attribution.md）',
];

const _mit = '''
Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.''';

const _bsd3 = '''
Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

- Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
- Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
- Neither the name of the copyright holders nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.''';

const _apache2 = '''
Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.''';

/// pub.dev 以外でアプリに入っているもの・出典の表示が必要なデータ（パッケージ名, 本文）。
@visibleForTesting
const extraLicenses = <(String, String)>[
  (
    'VOICEVOX CORE',
    'MIT License\n\nCopyright (c) 2021 Hiroshiba Kazuyuki\n$_mit',
  ),
  (
    'ONNX Runtime (VOICEVOX build)',
    'MIT License\n\nCopyright (c) Microsoft Corporation\n$_mit',
  ),
  (
    'Open JTalk dictionary (open_jtalk_dic_utf_8-1.11)',
    'Modified BSD License\n\n'
        'Copyright (c) 2009, Nara Institute of Science and Technology, Japan.\n'
        'Copyright (c) 2011-2017 Nagoya Institute of Technology, Department of Computer Science\n'
        '$_bsd3',
  ),
  (
    'VOICEVOX:ずんだもん',
    '読み上げの声「${VoicevoxTtsEngine.credit}」は、VOICEVOX の音声モデルの利用規約と'
        'ずんだもんの利用規約（東北ずん子・ずんだもんプロジェクト）に従って使っています。\n'
        'https://voicevox.hiroshiba.jp/\nhttps://zunko.jp/con_ongen_kiyaku.html',
  ),
  (
    'Kotlin Standard Library',
    'Copyright 2010-2026 JetBrains s.r.o. and Kotlin Programming Language contributors.\n$_apache2',
  ),
  (
    'OpenStreetMap',
    '© OpenStreetMap contributors\n\n'
        'ランドマークの位置・形と横断歩道・信号のデータは OpenStreetMap から取り出して加工したもので、'
        'Open Database License (ODbL) 1.0 で提供されています。\n'
        'https://www.openstreetmap.org/copyright',
  ),
  (
    '位置参照情報（国土交通省）',
    '「位置参照情報」（国土交通省）を加工して作成\nhttps://nlftp.mlit.go.jp/isj/',
  ),
  (
    '気象庁 防災情報XML',
    '出典：気象庁ホームページ（公共データ利用規約 第1.0版）。'
        '富山市の警報の種類とレベルを取り出し、文に加工して作成しています。\n'
        'https://www.jma.go.jp/jma/kishou/info/coment.html',
  ),
  (
    '富山市オープンデータ',
    '「インフォマップとやま 観光情報マップ 文化財情報」（富山市）CC BY をもとに作成\n'
        'https://opdt.city.toyama.lg.jp/dataset/infomap-toyama12',
  ),
];

bool _registered = false;

/// [extraLicenses] を Flutter のライセンス一覧に足す。何度呼んでも1回だけ足す。
void registerExtraLicenses() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(() async* {
    for (final (name, text) in extraLicenses) {
      yield LicenseEntryWithLineBreaks([name], text);
    }
  });
}

/// ライセンスの一覧を開く。
void showAppLicenses(BuildContext context) {
  registerExtraLicenses();
  showLicensePage(
    context: context,
    applicationName: 'アンビエント・ナラティブガイド',
    applicationLegalese: dataAttributions.join('\n'),
  );
}
