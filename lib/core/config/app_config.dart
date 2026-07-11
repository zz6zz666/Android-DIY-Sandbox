const bool product = bool.fromEnvironment('dart.vm.product');

class Config {
  // Ubuntu系统镜像文件名
  static const String ubuntuFileName = 'ubuntu-noble-aarch64-pd-v4.18.0.tar.xz';

  // GitHub 仓库信息
  static const String githubOwner = 'zz6zz666';
  static const String githubRepo = 'Android-DIY-Sandbox';
  static const String githubReleasesPath =
      '/repos/$githubOwner/$githubRepo/releases/latest';

  // GitHub API 镜像源列表 (代理前缀; 检查更新时先直连 api.github.com 再回退这些)
  static const List<String> githubApiMirrors = [
    'https://ghfast.top',
    'https://gh-proxy.com',
    'https://ghproxy.net',
    'https://gh.dpik.top',
    'https://gh.monlor.com',
  ];

  // GitHub 官方 API
  static const String githubApi = 'https://api.github.com';

  // GitHub 官方下载地址
  static const String githubDownloadBase =
      'https://github.com/$githubOwner/$githubRepo/releases/download';

  // 下载镜像源列表 (代理前缀; 下载 APK 时对这些镜像测速后由用户选择)
  static const List<Map<String, String>> downloadMirrors = [
    {'name': 'Ghfast', 'url': 'https://ghfast.top'},
    {'name': 'Gh-Proxy', 'url': 'https://gh-proxy.com'},
    {'name': 'GhProxyNet', 'url': 'https://ghproxy.net'},
    {'name': 'GhProxyCc', 'url': 'https://ghproxy.cc'},
    {'name': 'Dpik', 'url': 'https://gh.dpik.top'},
    {'name': 'Monlor', 'url': 'https://gh.monlor.com'},
    {'name': 'Chjina', 'url': 'https://gh.chjina.com'},
    {'name': 'BokiMoe', 'url': 'https://github.boki.moe'},
    {'name': 'JasonZeng', 'url': 'https://gh.jasonzeng.dev'},
    {'name': 'GeekerTao', 'url': 'https://gh.geekertao.top'},
    {'name': 'Nxnow', 'url': 'https://gh.nxnow.top'},
    {'name': 'Npee', 'url': 'https://down.npee.cn'},
  ];
}
