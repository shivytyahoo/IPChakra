// Country reference data and remark parsing for Stealth servers.
//
// A stealth share link carries no structured country field — the
// only place a feed can state the country is the free-text remark
// (the URI fragment, or a VMess `ps` field). Feeds write remarks in
// wildly different conventions: a leading flag emoji, a leading
// ISO code ("NL-193.29…"), a code after the protocol word
// ("vless-AL-1"), an English country name, or a Chinese country
// name. [countryCodeFromRemark] reads all of those, in a strict
// priority order, and validates every candidate against the full
// ISO 3166-1 table below — a two-letter fragment of a longer word
// is never mistaken for a code (the pre-v2.3.3 parser searched for
// any `[A-Z]{2}-` substring, which read "ET" out of "PLANB_NET",
// "AY" out of "RELAY" and "PN" out of "VPN", and collapsed every
// other remark into a group literally named "Unknown").
//
// Remarks that carry no country in any convention (some feeds
// publish only a brand name or a channel handle) honestly yield
// null — the app never invents a country for them.

/// ISO 3166-1 alpha-2 code -> English short name. Includes the EU
/// (a reserved ISO code the feeds use for multi-country relays).
const Map<String, String> kCountryNames = {
  'AD': 'Andorra',
  'AE': 'United Arab Emirates',
  'AF': 'Afghanistan',
  'AG': 'Antigua and Barbuda',
  'AI': 'Anguilla',
  'AL': 'Albania',
  'AM': 'Armenia',
  'AO': 'Angola',
  'AQ': 'Antarctica',
  'AR': 'Argentina',
  'AS': 'American Samoa',
  'AT': 'Austria',
  'AU': 'Australia',
  'AW': 'Aruba',
  'AX': 'Åland Islands',
  'AZ': 'Azerbaijan',
  'BA': 'Bosnia and Herzegovina',
  'BB': 'Barbados',
  'BD': 'Bangladesh',
  'BE': 'Belgium',
  'BF': 'Burkina Faso',
  'BG': 'Bulgaria',
  'BH': 'Bahrain',
  'BI': 'Burundi',
  'BJ': 'Benin',
  'BL': 'Saint Barthélemy',
  'BM': 'Bermuda',
  'BN': 'Brunei',
  'BO': 'Bolivia',
  'BQ': 'Bonaire',
  'BR': 'Brazil',
  'BS': 'Bahamas',
  'BT': 'Bhutan',
  'BV': 'Bouvet Island',
  'BW': 'Botswana',
  'BY': 'Belarus',
  'BZ': 'Belize',
  'CA': 'Canada',
  'CC': 'Cocos Islands',
  'CD': 'DR Congo',
  'CF': 'Central African Republic',
  'CG': 'Congo',
  'CH': 'Switzerland',
  'CI': "Côte d'Ivoire",
  'CK': 'Cook Islands',
  'CL': 'Chile',
  'CM': 'Cameroon',
  'CN': 'China',
  'CO': 'Colombia',
  'CR': 'Costa Rica',
  'CU': 'Cuba',
  'CV': 'Cape Verde',
  'CW': 'Curaçao',
  'CX': 'Christmas Island',
  'CY': 'Cyprus',
  'CZ': 'Czechia',
  'DE': 'Germany',
  'DJ': 'Djibouti',
  'DK': 'Denmark',
  'DM': 'Dominica',
  'DO': 'Dominican Republic',
  'DZ': 'Algeria',
  'EC': 'Ecuador',
  'EE': 'Estonia',
  'EG': 'Egypt',
  'EH': 'Western Sahara',
  'ER': 'Eritrea',
  'ES': 'Spain',
  'ET': 'Ethiopia',
  'EU': 'Europe',
  'FI': 'Finland',
  'FJ': 'Fiji',
  'FK': 'Falkland Islands',
  'FM': 'Micronesia',
  'FO': 'Faroe Islands',
  'FR': 'France',
  'GA': 'Gabon',
  'GB': 'United Kingdom',
  'GD': 'Grenada',
  'GE': 'Georgia',
  'GF': 'French Guiana',
  'GG': 'Guernsey',
  'GH': 'Ghana',
  'GI': 'Gibraltar',
  'GL': 'Greenland',
  'GM': 'Gambia',
  'GN': 'Guinea',
  'GP': 'Guadeloupe',
  'GQ': 'Equatorial Guinea',
  'GR': 'Greece',
  'GS': 'South Georgia',
  'GT': 'Guatemala',
  'GU': 'Guam',
  'GW': 'Guinea-Bissau',
  'GY': 'Guyana',
  'HK': 'Hong Kong',
  'HM': 'Heard Island',
  'HN': 'Honduras',
  'HR': 'Croatia',
  'HT': 'Haiti',
  'HU': 'Hungary',
  'ID': 'Indonesia',
  'IE': 'Ireland',
  'IL': 'Israel',
  'IM': 'Isle of Man',
  'IN': 'India',
  'IO': 'British Indian Ocean Territory',
  'IQ': 'Iraq',
  'IR': 'Iran',
  'IS': 'Iceland',
  'IT': 'Italy',
  'JE': 'Jersey',
  'JM': 'Jamaica',
  'JO': 'Jordan',
  'JP': 'Japan',
  'KE': 'Kenya',
  'KG': 'Kyrgyzstan',
  'KH': 'Cambodia',
  'KI': 'Kiribati',
  'KM': 'Comoros',
  'KN': 'Saint Kitts and Nevis',
  'KP': 'North Korea',
  'KR': 'South Korea',
  'KW': 'Kuwait',
  'KY': 'Cayman Islands',
  'KZ': 'Kazakhstan',
  'LA': 'Laos',
  'LB': 'Lebanon',
  'LC': 'Saint Lucia',
  'LI': 'Liechtenstein',
  'LK': 'Sri Lanka',
  'LR': 'Liberia',
  'LS': 'Lesotho',
  'LT': 'Lithuania',
  'LU': 'Luxembourg',
  'LV': 'Latvia',
  'LY': 'Libya',
  'MA': 'Morocco',
  'MC': 'Monaco',
  'MD': 'Moldova',
  'ME': 'Montenegro',
  'MF': 'Saint Martin',
  'MG': 'Madagascar',
  'MH': 'Marshall Islands',
  'MK': 'North Macedonia',
  'ML': 'Mali',
  'MM': 'Myanmar',
  'MN': 'Mongolia',
  'MO': 'Macao',
  'MP': 'Northern Mariana Islands',
  'MQ': 'Martinique',
  'MR': 'Mauritania',
  'MS': 'Montserrat',
  'MT': 'Malta',
  'MU': 'Mauritius',
  'MV': 'Maldives',
  'MW': 'Malawi',
  'MX': 'Mexico',
  'MY': 'Malaysia',
  'MZ': 'Mozambique',
  'NA': 'Namibia',
  'NC': 'New Caledonia',
  'NE': 'Niger',
  'NF': 'Norfolk Island',
  'NG': 'Nigeria',
  'NI': 'Nicaragua',
  'NL': 'Netherlands',
  'NO': 'Norway',
  'NP': 'Nepal',
  'NR': 'Nauru',
  'NU': 'Niue',
  'NZ': 'New Zealand',
  'OM': 'Oman',
  'PA': 'Panama',
  'PE': 'Peru',
  'PF': 'French Polynesia',
  'PG': 'Papua New Guinea',
  'PH': 'Philippines',
  'PK': 'Pakistan',
  'PL': 'Poland',
  'PM': 'Saint Pierre and Miquelon',
  'PN': 'Pitcairn',
  'PR': 'Puerto Rico',
  'PS': 'Palestine',
  'PT': 'Portugal',
  'PW': 'Palau',
  'PY': 'Paraguay',
  'QA': 'Qatar',
  'RE': 'Réunion',
  'RO': 'Romania',
  'RS': 'Serbia',
  'RU': 'Russia',
  'RW': 'Rwanda',
  'SA': 'Saudi Arabia',
  'SB': 'Solomon Islands',
  'SC': 'Seychelles',
  'SD': 'Sudan',
  'SE': 'Sweden',
  'SG': 'Singapore',
  'SH': 'Saint Helena',
  'SI': 'Slovenia',
  'SJ': 'Svalbard and Jan Mayen',
  'SK': 'Slovakia',
  'SL': 'Sierra Leone',
  'SM': 'San Marino',
  'SN': 'Senegal',
  'SO': 'Somalia',
  'SR': 'Suriname',
  'SS': 'South Sudan',
  'ST': 'São Tomé and Príncipe',
  'SV': 'El Salvador',
  'SX': 'Sint Maarten',
  'SY': 'Syria',
  'SZ': 'Eswatini',
  'TC': 'Turks and Caicos Islands',
  'TD': 'Chad',
  'TF': 'French Southern Territories',
  'TG': 'Togo',
  'TH': 'Thailand',
  'TJ': 'Tajikistan',
  'TK': 'Tokelau',
  'TL': 'Timor-Leste',
  'TM': 'Turkmenistan',
  'TN': 'Tunisia',
  'TO': 'Tonga',
  'TR': 'Turkey',
  'TT': 'Trinidad and Tobago',
  'TV': 'Tuvalu',
  'TW': 'Taiwan',
  'TZ': 'Tanzania',
  'UA': 'Ukraine',
  'UG': 'Uganda',
  'UM': 'U.S. Minor Outlying Islands',
  'US': 'United States',
  'UY': 'Uruguay',
  'UZ': 'Uzbekistan',
  'VA': 'Vatican City',
  'VC': 'Saint Vincent and the Grenadines',
  'VE': 'Venezuela',
  'VG': 'British Virgin Islands',
  'VI': 'U.S. Virgin Islands',
  'VN': 'Vietnam',
  'VU': 'Vanuatu',
  'WF': 'Wallis and Futuna',
  'WS': 'Samoa',
  'YE': 'Yemen',
  'YT': 'Mayotte',
  'ZA': 'South Africa',
  'ZM': 'Zambia',
  'ZW': 'Zimbabwe',
};

/// Normalize a code the way the feeds mean it: 'UK' is the United
/// Kingdom (ISO reserves GB), and 'UM' (U.S. Minor Outlying
/// Islands) is how a large share of feed authors write the United
/// States — its flag emoji is the one their tools emit for the US.
String _normalizeCode(String code) {
  final upper = code.toUpperCase();
  if (upper == 'UK') return 'GB';
  if (upper == 'UM') return 'US';
  return upper;
}

/// The English name for an ISO alpha-2 [code] ('UK' is accepted as
/// the United Kingdom, as the feeds write it), or null when the
/// code is not a real country code.
String? countryNameForCode(String code) {
  return kCountryNames[_normalizeCode(code)];
}

/// The flag emoji for an ISO alpha-2 [code], computed from the
/// regional indicator symbols — every real code has one, unlike a
/// hand-maintained lookup table that silently runs out. Returns
/// '🌐' for anything that is not a two-letter code.
String flagEmojiForCode(String code) {
  final normalized = _normalizeCode(code);
  if (normalized.length != 2) return '🌐';
  final a = normalized.codeUnitAt(0);
  final b = normalized.codeUnitAt(1);
  bool isLetter(int u) => u >= 0x41 && u <= 0x5A;
  if (!isLetter(a) || !isLetter(b)) return '🌐';
  return String.fromCharCodes([0x1F1E6 + (a - 0x41), 0x1F1E6 + (b - 0x41)]);
}

/// Non-ISO spellings the feeds use, mapped to ISO codes.
const Map<String, String> _codeAliases = {
  'UK': 'GB',
  'USA': 'US',
  'UAE': 'AE',
};

/// Extra English names the feeds write that differ from the ISO
/// short name, mapped to codes. Searched together with the ISO
/// names, longest first.
const Map<String, String> _extraEnglishNames = {
  'czech republic': 'CZ',
  'korea': 'KR',
  'ivory coast': 'CI',
  'vatican': 'VA',
  'congo republic': 'CG',
  'east timor': 'TL',
  'cape verde islands': 'CV',
};

/// Chinese country names used by some feeds (Pawdroid's remarks
/// are Chinese-only), mapped to ISO codes.
const Map<String, String> _chineseNames = {
  '美国': 'US',
  '英国': 'GB',
  '德国': 'DE',
  '法国': 'FR',
  '日本': 'JP',
  '韩国': 'KR',
  '乌克兰': 'UA',
  '立陶宛': 'LT',
  '俄罗斯': 'RU',
  '加拿大': 'CA',
  '澳大利亚': 'AU',
  '荷兰': 'NL',
  '新加坡': 'SG',
  '香港': 'HK',
  '台湾': 'TW',
  '中国': 'CN',
  '印度': 'IN',
  '印度尼西亚': 'ID',
  '印尼': 'ID',
  '越南': 'VN',
  '泰国': 'TH',
  '马来西亚': 'MY',
  '菲律宾': 'PH',
  '土耳其': 'TR',
  '意大利': 'IT',
  '西班牙': 'ES',
  '波兰': 'PL',
  '瑞典': 'SE',
  '瑞士': 'CH',
  '芬兰': 'FI',
  '挪威': 'NO',
  '丹麦': 'DK',
  '爱尔兰': 'IE',
  '奥地利': 'AT',
  '比利时': 'BE',
  '葡萄牙': 'PT',
  '希腊': 'GR',
  '罗马尼亚': 'RO',
  '保加利亚': 'BG',
  '匈牙利': 'HU',
  '捷克': 'CZ',
  '斯洛伐克': 'SK',
  '克罗地亚': 'HR',
  '塞尔维亚': 'RS',
  '爱沙尼亚': 'EE',
  '拉脱维亚': 'LV',
  '白俄罗斯': 'BY',
  '哈萨克斯坦': 'KZ',
  '乌兹别克斯坦': 'UZ',
  '伊朗': 'IR',
  '伊拉克': 'IQ',
  '以色列': 'IL',
  '阿联酋': 'AE',
  '沙特阿拉伯': 'SA',
  '埃及': 'EG',
  '南非': 'ZA',
  '尼日利亚': 'NG',
  '肯尼亚': 'KE',
  '墨西哥': 'MX',
  '巴西': 'BR',
  '阿根廷': 'AR',
  '智利': 'CL',
  '哥伦比亚': 'CO',
  '秘鲁': 'PE',
  '委内瑞拉': 'VE',
  '新西兰': 'NZ',
  '巴基斯坦': 'PK',
  '孟加拉': 'BD',
  '斯里兰卡': 'LK',
  '尼泊尔': 'NP',
  '缅甸': 'MM',
  '柬埔寨': 'KH',
  '老挝': 'LA',
  '蒙古': 'MN',
};

/// Name -> code for the English-name search: every ISO short name
/// plus the extra spellings.
final Map<String, String> _englishNameToCode = () {
  final map = <String, String>{
    for (final e in kCountryNames.entries) e.value.toLowerCase(): e.key,
    ..._extraEnglishNames,
  };
  // A few ISO names are too generic to match safely inside prose
  // remarks (they are ordinary English words); their codes are
  // still found by the flag and token paths.
  map.remove('georgia'); // also a US state, all over remarks
  map.remove('jordan'); // also a personal name
  map.remove('chad'); // also a personal name
  return map;
}();

/// One combined pattern for the English-name search: every name as
/// an alternation branch, longest first (so at any position
/// "Nigeria" wins over "Niger" and "United States" over any shorter
/// overlap), bounded by non-letters (so "Mali" never matches inside
/// "Somalia"). A single compiled pattern keeps the per-remark cost
/// flat — this runs over tens of thousands of feed remarks.
final RegExp _englishNamePattern = () {
  final names = _englishNameToCode.keys.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  return RegExp(
    '(?<![a-z])(${names.map(RegExp.escape).join('|')})(?![a-z])',
  );
}();

/// Chinese names sorted longest first, built once.
final List<MapEntry<String, String>> _chineseNameIndex =
    _chineseNames.entries.toList()
      ..sort((a, b) => b.key.length.compareTo(a.key.length));

/// Maximal ASCII letter runs — the token scanner's unit.
final RegExp _letterRun = RegExp(r'[A-Za-z]+');

/// The ISO alpha-2 code a stealth [remark] states, or null when it
/// states none. The conventions are tried in a strict order — a
/// flag emoji is unambiguous, a bounded code token is validated
/// against the ISO table, and the name searches run last:
///
/// 1. A flag emoji (a regional-indicator pair) anywhere.
/// 2. A bounded all-caps token that is a real ISO code (or a known
///    alias): "NL-…", "[NL]", "vless-AL-1", "US_speednode". Tokens
///    are maximal letter runs, so fragments of longer words never
///    match, and lowercase runs never match.
/// 3. An English country name as a whole phrase ("United States",
///    "Germany", "Hong Kong" …), longest first.
/// 4. A Chinese country name (美国, 德国, …).
String? countryCodeFromRemark(String remark) {
  if (remark.isEmpty) return null;

  // 1. Flag emoji: two consecutive regional indicator symbols.
  final runes = remark.runes.toList();
  for (var i = 0; i + 1 < runes.length; i++) {
    final a = runes[i];
    final b = runes[i + 1];
    bool isIndicator(int r) => r >= 0x1F1E6 && r <= 0x1F1FF;
    if (isIndicator(a) && isIndicator(b)) {
      final code = String.fromCharCodes([
        0x41 + (a - 0x1F1E6),
        0x41 + (b - 0x1F1E6),
      ]);
      if (kCountryNames.containsKey(code)) return _normalizeCode(code);
    }
  }

  // 2. Bounded all-caps tokens. A token is a maximal run of ASCII
  // letters; only runs of exactly 2 (a code) or 3 (an alias) that
  // are entirely uppercase are candidates.
  for (final match in _letterRun.allMatches(remark)) {
    final token = match.group(0)!;
    if (token != token.toUpperCase()) continue;
    if (token.length == 2 && kCountryNames.containsKey(token)) {
      return _normalizeCode(token);
    }
    if ((token.length == 2 || token.length == 3) &&
        _codeAliases.containsKey(token)) {
      return _codeAliases[token];
    }
  }

  // 3. English country names as whole phrases.
  final nameMatch = _englishNamePattern.firstMatch(remark.toLowerCase());
  if (nameMatch != null) {
    final code = _englishNameToCode[nameMatch.group(1)];
    if (code != null) return code;
  }

  // 4. Chinese country names, longest first.
  for (final e in _chineseNameIndex) {
    if (remark.contains(e.key)) return e.value;
  }

  return null;
}
