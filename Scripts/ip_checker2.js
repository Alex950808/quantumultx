//geo_location_checker=http://ifconfig.co/json, https://raw.githubusercontent.com/Alex950808/quantumultx/master/Scripts/ip_checker2.js
if ($response.statusCode !== 200) $done();

if ($response.statusCode !== 200) $done();

try {
  const {
    ip,
    country,
    country_iso,
    latitude,
    longitude,
    time_zone,
    asn,
    asn_org
  } = JSON.parse($response.body);

  const flag = country_iso
    ? String.fromCodePoint(...[...country_iso.toUpperCase()].map(c => 0x1f1a5 + c.charCodeAt(0)))
    : '🏴‍☠️';

  const city = time_zone?.split('/')[1]?.replace(/_/g, ' ') || '未知';

  $done({
    title: `${flag}『${city}』`,
    subtitle: `💋 ${asn_org || 'Cross-GFW.org'} ➠ ${country || '未知'}`,
    ip,
    description: [
      `国家: ${country}`,
      `城市: ${city}`,
      `IP: ${ip}`,
      `ASN: ${asn}`,
      `服务商: ${asn_org}`,
      `时区: ${time_zone}`,
      `定位: [${latitude},${longitude}]`
    ].join('\n')
  });
} catch {
  $done();
}
