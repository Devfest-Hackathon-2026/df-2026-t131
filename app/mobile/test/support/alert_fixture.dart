/// テスト用の警報の data（サーバーの `/mock-alert` が FCM で送る形と同じ。
/// 文もサーバーの模擬の警報と同じ決まり：頭に「これは訓練用の模擬の警報で、実際の警報ではありません。」）。
/// アプリ本体では警報を作らないので、テストの中だけで使う。
Map<String, String> mockAlertData({required int level, required int nowMs}) => {
  'schema_version': '0.3',
  'type': 'alert',
  'alert_id': 'mock_test_$nowMs',
  'level': '$level',
  'kind': level >= 4 ? '大雨危険警報' : '大雨警報',
  'area_code': '1620100',
  'area_name': '富山市',
  'text':
      'これは訓練用の模擬の警報で、実際の警報ではありません。富山市に'
      '${level >= 4 ? '警戒レベル4の大雨危険警報' : '警戒レベル3の大雨警報'}が出た、という想定です。',
};
