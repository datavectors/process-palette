_ = require 'underscore-plus'
shell = require 'shelljs'
ProcessConfig = require '../process-config'
{Directory, File} = require 'atom'
# {BufferedProcess} = require 'atom'

# Fields :
# stdout : Standard output.
# stderr : Standard error output.
# exitStatus : Code returned by command.
# clipboard : Text currently on clipboard.
# fullCommand : The full command along with its arguments.
# configDirAbsPath : Absolute path of folder that the configuration file is in.
# projectPath : Absolute path of project folder.
#
# Only if a file is currently open :
# fileExt : Extension of file.
# fileName : Name of file without extension.
# fileNameExt : Name of file with extension.
# filePath : Path of file relative to project.
# fileDirPath : Path of file's directory relative to project.
# fileAbsPath : Absolute path of file.
# fileDirAbsPath : Absolute path of file's directory.
# selection : Currently selected text.
# fileProjectPath : Absolute path of project folder.

module.exports =
class ProcessController

  @config : null;
  @disposable : null;
  @process : null;
  @processCallbacks : null;

  constructor: (@projectController, @config) ->
    @processCallbacks = [];
    @replaceRegExp = new RegExp('{.*?}','g');
    @fields = {};
    @output = '';
    cssSelector = 'atom-workspace';

    if (@config.outputTarget == 'editor')
      cssSelector = 'atom-text-editor';

    @disposable = atom.commands.add(cssSelector, @config.getCommandName(), @runProcess);

    if @config.keystroke
      binding = {};
      bindings = {};
      binding[@config.keystroke] = @config.getCommandName();
      bindings[cssSelector] = binding;

      # params = {};
      # params.keystrokes = @config.keystroke;
      # params.command = @config.getCommandName();
      # params.target = cssSelector;
      #
      # try
      #   console.log(atom.keymaps.findKeyBindings(params));
      # catch error
      #   console.log(error);

      atom.keymaps.add('process-palette', bindings);

  dispose: ->
    # TODO : The key binding should preferably be removed, but atom.keymaps.findKeyBindings throws an error.
    @disposable.dispose();

  runProcess: =>
    editor = atom.workspace.getActiveTextEditor();

    if editor
      @runProcessWithFile(editor.getPath());
    else
      @runProcessWithFile(null);

  runProcessWithFile: (filePath) =>
    if @process
      return;

    @fields = {};
    options = {};
    @output = '';

    @fields.clipboard = atom.clipboard.read();
    @fields.configDirAbsPath = @projectController.projectPath;
    @fields.stdout = '';
    @fields.stderr = '';

    projectPaths = atom.project.getPaths();

    if projectPaths.length > 0
      @fields.projectPath = projectPaths[0];
    else
      @fields.projectPath = @projectController.projectPath;

    editor = atom.workspace.getActiveTextEditor();

    if editor
      @fields.selection = editor.getSelectedText();

    if filePath
      file = new File(filePath);

      nameExt = @splitFileName(file.getBaseName());
      @fields.fileName = nameExt[0];
      @fields.fileExt = nameExt[1];

      @fields.fileNameExt = file.getBaseName();
      @fields.fileAbsPath = file.getRealPathSync();
      @fields.fileDirAbsPath = file.getParent().getRealPathSync();

      relPaths = atom.project.relativizePath(@fields.fileAbsPath);
      @fields.fileProjectPath = relPaths[0];
      @fields.filePath = relPaths[1];

      relPaths = atom.project.relativizePath(@fields.fileDirAbsPath);
      @fields.fileDirPath = relPaths[1];
    else
      @fields.fileName = '';
      @fields.fileExt = '';
      @fields.fileNameExt = '';
      @fields.fileAbsPath = '';
      @fields.fileDirAbsPath = '';
      @fields.filePath = '';
      @fields.fileDirPath = '';
      @fields.fileProjectPath = '';
      @fields.selection = '';

    if @config.cwd
      options.cwd = @insertFields(@config.cwd);
    else
      options.cwd = @fields.projectPath;

    command = @insertFields(@config.command);

    args = [];
    for argument in @config.arguments
      args.push(@insertFields(argument));

    @fields.fullCommand = command;

    if args.length > 0
      @fields.fullCommand += " " + args.join(" ");
      @fields.fullCommand = @fields.fullCommand.trim();

    @envBackup = {};
    @pwdBackup = shell.pwd();

    if @config.env != null
      for key, val of @config.env
        @envBackup[key] = shell.env[key];
        shell.env[key] = @insertFields(val);

    shell.cd(options.cwd);

    @process = shell.exec @fields.fullCommand, {silent:true, async:true}, (code) =>
      @fields.exitStatus = code;
      @processStopped(false, !code?);

    @process.stdout.on 'data', (data) =>
      if @config.stream
        @streamOutput(data);
      else
        @fields.stdout += data;

    @process.stderr.on 'data', (data) =>
      if @config.stream
        @streamOutput(data);
      else
        @fields.stderr += data;

    @processStarted();

  splitFileName: (fileNameExt) ->
    index = fileNameExt.lastIndexOf(".");

    if index == -1
      return [fileNameExt, ""];

    return [fileNameExt.substr(0, index), fileNameExt.substr(index+1)];

  insertFields: (text) =>
    return text.replace(@replaceRegExp, @createReplaceCallback(@fields));

  createReplaceCallback: (fields) ->
    return (text) =>
      return fields[text.slice(1,-1)];

  addProcessCallback: (callback) ->
    @processCallbacks.push(callback);

  removeProcessCallback: (callback) ->
    index = @processCallbacks.indexOf(callback);

    if (index != -1)
      @processCallbacks.splice(index, 1);

  runKillProcess: ->
    if @process
      @killProcess();
    else
      @runProcess();

  killProcess:  ->
    if !@process
      return;

    @process.kill();
    @processStopped(false, true);

  handleProcessErrorCallback: (errorObject) =>
    # Indicate that the error has been handled.
    errorObject.handle();
    @processStopped(true, false);

  streamOutput: (output) ->
    @outputToTarget(output, true);

    for processCallback in @processCallbacks
      if typeof processCallback.streamOutput is 'function'
        processCallback.streamOutput(output);

  processStarted: ->
    for processCallback in @processCallbacks
      if typeof processCallback.processStarted is 'function'
        processCallback.processStarted();

  processStopped: (fatal, killed) =>
    output = '';
    messageTitle = _.humanizeEventName(@config.getCommandName());
    options = {};

    if !killed
      if fatal
        if @config.fatalMessage?
          options["detail"] = @insertFields(@config.fatalMessage);
          atom.notifications.addError(messageTitle, options);
      else if @fields.exitStatus == 0
        if @config.successMessage?
          options["detail"] = @insertFields(@config.successMessage);
          atom.notifications.addSuccess(messageTitle, options);
      else
        if @config.errorMessage?
          options["detail"] = @insertFields(@config.errorMessage);
          atom.notifications.addWarning(messageTitle, options);

    if !@config.stream
      if fatal
        if @config.fatalOutput?
          output = @insertFields(@config.fatalOutput);
      else if @fields.exitStatus == 0
        if @config.successOutput?
          output = @insertFields(@config.successOutput);
      else
        if @config.errorOutput?
          output = @insertFields(@config.errorOutput);

      @outputToTarget(output, false);

    for key, val of @envBackup
      if _.isUndefined(@envBackup[key])
        delete shell.env[key];
      else
        shell.env[key] = @envBackup[key];

    shell.cd(@pwdBackup);

    @process = null;
    @fields = {};

    for processCallback in @processCallbacks
      if typeof processCallback.processStopped is 'function'
        processCallback.processStopped();

  outputToTarget: (output, stream) ->
    if (@config.outputTarget == 'editor')
      editor = atom.workspace.getActiveTextEditor();

      if editor?
        editor.insertText(output);
    else if (@config.outputTarget == 'clipboard')
      if stream
        @output += output;
        atom.clipboard.write(@output);
      else
        atom.clipboard.write(output);
    else if (@config.outputTarget == 'console')
      console.log(output);
    else if (@config.outputTarget == 'panel')
      if stream
        @output += output;
      else
        @output = output;
