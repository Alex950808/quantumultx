if ($response.statusCode !== 200) $done();

try {
  const { country, countryCode, city, isp, org, query: ip, timezone, lat, lon } = JSON.parse($response.body);

  // 利用 ISO 3166-1 alpha-2 区域指示符直接计算国旗 Emoji
  const flag = countryCode
    ? String.fromCodePoint(...[...countryCode.toUpperCase()].map(c => 0x1f1a5 + c.charCodeAt(0)))
    : '🏴‍☠️';

  $done({
    title: `${flag}『${city || '未知'}』`,
    subtitle: `💋 ${isp || 'Cross-GFW.org'} ➠ ${country || '未知'}`,
    ip,
    description: [
      `国家: ${country}`,
      `城市: ${city}`,
      `IP: ${ip}`,
      `时区: ${timezone}`,
      `定位: [${lat},${lon}]`,
      `服务商: ${isp}`,
      `数据中心: ${org}`
    ].join('\n')
  });
} catch {
  $done();
}
