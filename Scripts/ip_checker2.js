//geo_location_checker=https://my.ippure.com/v1/info, https://raw.githubusercontent.com/Alex950808/quantumultx/master/Scripts/ip_checker2.js
if ($response.statusCode !== 200) $done();

try {
  const {
    ip,
    country,
    countryCode,
    city,
    region,
    timezone,
    latitude,
    longitude,
    asOrganization,
    asn,
    fraudScore,
    isResidential,
    isBroadcast
  } = JSON.parse($response.body);

  // 双字母代码转换为国旗 Emoji
  const flag = countryCode
    ? String.fromCodePoint(...[...countryCode.toUpperCase()].map(c => 0x1f1a5 + c.charCodeAt(0)))
    : '🏴‍☠️';

  const resType = isResidential ? '家宽' : '机房';
  const broadcastType = isBroadcast ? '广播' : '原生';

  $done({
    title: `${flag}『${city || '未知'}』`,
    subtitle: `💋 ${asOrganization || 'Cross-GFW.org'} ➠ ${country || '未知'}`,
    ip,
    description: [
      `国家: ${country}`,
      `地区: ${region}`,
      `城市: ${city}`,
      `IP: ${ip}`,
      `属性: ${broadcastType} | ${resType}`,
      `ASN: AS${asn} (${asOrganization})`,
      `欺诈分: ${fraudScore ?? '未知'}`,
      `时区: ${timezone}`,
      `定位: [${latitude},${longitude}]`
    ].join('\n')
  });
} catch {
  $done();
}
