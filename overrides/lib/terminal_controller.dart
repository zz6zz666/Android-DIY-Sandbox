import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:get/get.dart';
import 'package:global_repository/global_repository.dart';
import 'package:settings/settings.dart';
import 'package:xterm/xterm.dart';
import 'config.dart';
import 'generated/l10n.dart';
import 'script.dart';
import 'utils.dart';

class HomeController extends GetxController {
  // bool vsCodeStaring = false;
  SettingNode privacySetting = 'privacy'.setting;
  Pty? pseudoTerminal;
  late Terminal terminal = Terminal(
    maxLines: 10000,
    onResize: (width, height, pixelWidth, pixelHeight) {
      pseudoTerminal?.resize(height, width);
    },
    onOutput: (data) {
      pseudoTerminal?.writeString(data);
    },
  );
  bool webviewHasOpen = false;

  File progressFile = File('${RuntimeEnvir.tmpPath}/progress');
  File progressDesFile = File('${RuntimeEnvir.tmpPath}/progress_des');
  double progress = 0.0;
  double step = 8; // 修改为8个步骤（install_proot_distro, install_ubuntu, install_curl, network_test, install_uv, install_astrobot, install_napcat）
  String currentProgress = '';

  // 进度 +1
  // Progress +1
  void bumpProgress() {
    try {
      int current = 0;
      if (progressFile.existsSync()) {
        final content = progressFile.readAsStringSync().trim();
        if (content.isNotEmpty) {
          current = int.tryParse(content) ?? 0;
        }
      } else {
        progressFile.createSync(recursive: true);
      }
      progressFile.writeAsStringSync('${current + 1}');
    } catch (e) {
      progressFile.writeAsStringSync('1');
    }
    update();
  }

  // 监听输出，当输出中包含启动成功的标志时，启动 Code Server
  // Listen for output and start the Code Server when the success flag is detected
  Future<void> astrBotStartWhenSuccessBind() async {
    terminal.writeProgress('${S.current.listen_vscode_start}...');
    final Completer completer = Completer();
    Utf8Decoder decoder = const Utf8Decoder(allowMalformed: true);
    pseudoTerminal!.output.cast<List<int>>().transform(decoder).listen((event) async {
      if (event.contains('http://0.0.0.0:${Config.port}')) {
        Log.e(event);
        if (!completer.isCompleted) {
          completer.complete();
        }
      }
      if (event.contains('already')) {
        Log.e(event);
        if (!completer.isCompleted) {
          completer.complete();
        }
      }
      terminal.write(event);
    });
    await completer.future;
    bumpProgress();
    await Future.delayed(const Duration(milliseconds: 100));
    webviewHasOpen = true;
    openWebView();
    Future.delayed(const Duration(milliseconds: 2000), () {
      update();
    });
  }


  // 初始化环境，将动态库中的文件链接到数据目录
  // Init environment and link files from the dynamic library to the data directory
  Future<void> initEnvir() async {
    List<String> androidFiles = ['libbash.so', 'libbusybox.so', 'liblibtalloc.so.2.so', 'libloader.so', 'libproot.so', 'libsudo.so'];
    String libPath = await getLibPath();
    Log.i('libPath -> $libPath');

    for (int i = 0; i < androidFiles.length; i++) {
      // when android target sdk > 28
      // cannot execute file in /data/data/com.xxx/files/usr/bin
      // so we need create a link to /data/data/com.xxx/files/usr/bin
      final sourcePath = '$libPath/${androidFiles[i]}';
      String fileName = androidFiles[i].replaceAll(RegExp('^lib|\\.so\$'), '');
      String filePath = '${RuntimeEnvir.binPath}/$fileName';
      // custom path, termux-api will invoke
      File file = File(filePath);
      FileSystemEntityType type = await FileSystemEntity.type(filePath);
      Log.i('$fileName type -> $type');
      if (type != FileSystemEntityType.notFound && type != FileSystemEntityType.link) {
        // old version adb is plain file
        Log.i('find plain file -> $fileName, delete it');
        await file.delete();
      }
      Link link = Link(filePath);
      if (link.existsSync()) {
        link.deleteSync();
      }
      try {
        Log.i('create link -> $fileName ${link.path}');
        link.createSync(sourcePath);
      } catch (e) {
        Log.e('installAdbToEnvir error -> $e');
      }
    }
  }

  // 同步当前进度
  // Sync the current progress
  void syncProgress() {
    progressFile.createSync(recursive: true);
    progressFile.writeAsStringSync('0');
    progressFile.watch(events: FileSystemEvent.all).listen((event) async {
      if (event.type == FileSystemEvent.modify) {
        String content = await progressFile.readAsString();
        Log.e('content -> $content');
        if (content.isEmpty) {
          return;
        }
        progress = int.parse(content) / step;
        Log.e('progress -> $progress');
        update();
      }
    });
    progressDesFile.createSync(recursive: true);
    progressDesFile.writeAsStringSync('');
    progressDesFile.watch(events: FileSystemEvent.all).listen((event) async {
      if (event.type == FileSystemEvent.modify) {
        String content = await progressDesFile.readAsString();
        currentProgress = content;
        update();
      }
    });
  }

  // 创建 busybox 的软连接，来确保 proot-distro 会用到的命令正常运行
  // create busybox symlinks, to ensure proot-distro can use the commands normally
  void createBusyboxLink() {
    try {
      List<String> links = [
        ...['awk', 'ash', 'basename', 'bzip2', 'curl', 'cp', 'chmod', 'cut', 'cat', 'du', 'dd', 'find', 'grep', 'gzip'],
        ...['hexdump', 'head', 'id', 'lscpu', 'mkdir', 'realpath', 'rm', 'sed', 'stat', 'sh', 'tr', 'tar', 'uname', 'xargs', 'xz', 'xxd']
      ];

      for (String linkName in links) {
        Link link = Link('${RuntimeEnvir.binPath}/$linkName');
        if (!link.existsSync()) {
          link.createSync('${RuntimeEnvir.binPath}/busybox');
        }
      }
      Link link = Link('${RuntimeEnvir.binPath}/file');
      link.createSync('/system/bin/file');
    } catch (e) {
      Log.e('Create link failed -> $e');
    }
  }

  void setProgress(String description) {
    currentProgress = description;
    terminal.writeProgress(currentProgress);
  }

  Future<void> loadAstrBot() async {
    syncProgress();
    
    // 创建相关文件夹
    Directory(RuntimeEnvir.tmpPath).createSync(recursive: true);
    Directory(RuntimeEnvir.homePath).createSync(recursive: true);
    Directory(RuntimeEnvir.binPath).createSync(recursive: true);
    
    await initEnvir();
    createBusyboxLink();
    
    // 创建终端
    pseudoTerminal = createPTY(rows: terminal.viewHeight, columns: terminal.viewWidth);
    
    // 复制必要的文件
    setProgress('复制 proot-distro...');
    await AssetsUtils.copyAssetToPath('assets/proot-distro.zip', '${RuntimeEnvir.homePath}/proot-distro.zip');
    bumpProgress();
    
    setProgress('复制 Ubuntu 系统镜像...');
    await AssetsUtils.copyAssetToPath('assets/${Config.ubuntuFileName}', '${RuntimeEnvir.homePath}/${Config.ubuntuFileName}');
    await AssetsUtils.copyAssetToPath('assets/astrbot-startup.sh', '${RuntimeEnvir.homePath}/astrbot-startup.sh');
    bumpProgress();
    
    // 写入并执行脚本
    File('${RuntimeEnvir.homePath}/common.sh').writeAsStringSync('$commonScript');
    
    astrBotStartWhenSuccessBind();
    bumpProgress();
    // 启动 AstrBot 安装和运行流程
    startAstrBot(pseudoTerminal!);

  }
  
  Future<void> startAstrBot(Pty pseudoTerminal) async {
    setProgress('开始安装 AstrBot...');
    pseudoTerminal.writeString('source ${RuntimeEnvir.homePath}/common.sh\nstart_astrbot\n');
  }
  
  @override
  void onInit() {
    super.onInit();
    // 为 Google Play 上架做准备
    // For Google Play
    Future.delayed(Duration.zero, () async {
      if (privacySetting.get() == null) {
        await Get.to(PrivacyAgreePage(
          onAgreeTap: () {
            privacySetting.set(true);
            Get.back();
          },
        ));
      }
      
      // 加载并启动 AstrBot
      loadAstrBot();
    });
  }
}
