//
//  SANSpeechRecognition.swift
//  HueBase
//
//  Created by 花形春輝 on 2021/03/23.
//
import Foundation
import AVFoundation
import Speech

final class SpeechRecognitionEngine: ObservableObject {
    var audioRunning: Bool = false
    private var audioEngine = AVAudioEngine()
    private var speechRecognizer = SFSpeechRecognizer(locale: Locale.current)!
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    /// オンデバイス認識
    public var requiresOnDeviceRecognition = true
    /// true:途中報告 false:結果報告
    public var shouldReportPartialResults = false
    /// タスクヒント
    public var taskHint:SFSpeechRecognitionTaskHint = .unspecified
    /// 単語
    public var contextualStrings:[String]? = nil
    /// 最初の沈黙の時間
    public var firstSilenceTime:TimeInterval = 5
    /// 沈黙時間
    public var silenceTime:TimeInterval = 1
    /// init時の沈黙時間
    public var initSilenceTime:TimeInterval = 1
    /// タイマー終了時(最初に一定間隔喋らなかった時)
    public var onFirstFinishTask:(()->Void) = {}
    /// タイマー終了時(一定間隔喋らなかった時)
    public var onFinishTask:(()->Void) = {}
    /// 音声認識時メソッド
    public var onRecognition:(([String])->Void) = {_ in }
    /// タイムアウト
    public var onTimeout:(()->Void) = {}
    /// エラー発生時
    public var onError:((Error?)->Void) = {_ in }
    // タイマー設定
    private var timer:Timer?
    // 音声認識ステータス
    enum Status {
        case stop
        case start
    }
    var status:Status = .stop
    
    let lock = NSLock()

    /// 初期処理
    /// - Parameters:
    ///   - shouldReportPartialResults: true:途中報告 false:結果報告
    ///   - onRecognition: 音声認識時Call Back関数
    init(firstSilenceTime:TimeInterval = 5
         , silenceTime:TimeInterval = 0.5
         , shouldReportPartialResults:Bool = true
         , taskHint:SFSpeechRecognitionTaskHint = .unspecified
         , contextualStrings:[String]? = nil
         , onFirstFinishTask:@escaping (()->Void) = {}
         , onFinishTask:@escaping (()->Void) = {}
         , onRecognition:@escaping (([String])->Void) = {_ in }
         , onTimeout:@escaping (()->Void) = {}
         , onError:@escaping ((Error?)->Void) = {_ in }) {
        self.shouldReportPartialResults = shouldReportPartialResults
        self.firstSilenceTime = firstSilenceTime
        self.silenceTime = silenceTime
        self.contextualStrings = contextualStrings
        self.initSilenceTime = silenceTime
        self.onFirstFinishTask = onFirstFinishTask
        self.onFinishTask = onFinishTask
        self.onRecognition = onRecognition
        self.onTimeout = onTimeout
        self.onError = onError
        self.taskHint = taskHint
    }
    
    /// マイク・音声認識使用許可確認
    /// - Returns: True:許諾済 False:許諾拒否
    func authorization()->Bool{
        if(AVCaptureDevice.authorizationStatus(for: AVMediaType.audio) == .authorized &&
            SFSpeechRecognizer.authorizationStatus() == .authorized){
            return true
        } else {
            return false
        }
    }
    
    /// マイク・音声認識使用許可要求
    /// - Parameter completion: コールバック関数
    func requestAccess(completion:@escaping ()->Void){
        /// マイク使用許可
        AVCaptureDevice.requestAccess(for: AVMediaType.audio) { granted in
            if granted {
                /// 音声認識使用許可
                SFSpeechRecognizer.requestAuthorization { status in
                    completion()
                }
            } else {
                completion()
            }
        }
    }

    /// 音声認識開始
    func startRecording() throws {
        print("startRecording")

        // 開始済みなら処理終了
        if status == .start { return }
        
        // ロック
        self.lock.lock()
        defer { self.lock.unlock() }  // unlock を保証
        
        // 録音開始
        status = .start

        // AVAudioSessionの初期化
        // AVAudioSessionインタンスの取得
        let audioSession = AVAudioSession.sharedInstance()
        // カテゴリーの指定(アプリの音の扱い方法を指定)
        try audioSession.setCategory(.playAndRecord, mode: .measurement, options: .duckOthers)
        // AVAutdioのアクティブ化
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        // 入力モードの指定
        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        
        // 音声認識の初期化
        // SFSpeechRecognizerのインスタンス化
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale.current)!
        // オンデバイス判定
        if speechRecognizer.supportsOnDeviceRecognition {
            recognitionRequest?.requiresOnDeviceRecognition = self.requiresOnDeviceRecognition
        }
        // タスクを設定 値を受け取った時のタスク
        self.recognitionTask = SFSpeechRecognitionTask()

        // リクエストの作成　マイク等のオーディオバッファを利用 ライブストリーム用
        self.recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        if(self.recognitionTask == nil || self.recognitionRequest == nil){
            self.stopRecording()
            return
        }
        // 単語
        if let contextualStrings = contextualStrings {
            self.recognitionRequest?.contextualStrings = contextualStrings
        }
        
        // タイマー設定
        timer = Timer.scheduledTimer(timeInterval: silenceTime, target: self, selector: #selector(self.didFinishTalk), userInfo: nil, repeats: false)
        
        // true:途中報告 false:結果報告
        recognitionRequest?.shouldReportPartialResults = shouldReportPartialResults
        
        // 音声認識
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest!) { [self] result, error in
            if status != .start { return }
            if(error != nil){
                var errorCode = 0
                
                // エラーコード取得
                if let e = error as NSError? {
                    errorCode = e.code
                }
                // エラー発生時
                print ("SpeechRecognizer error:" + String(describing: error))

                // エラーコード301は無視
                if errorCode == 301 {
                    print("recognition cancel status:\(status)")
                    // タイマーキル
                    makeFinishTimer(0)
                    return
                } else if errorCode != 209 && errorCode != 1110 {
                    // エラーコード209,1110以外はエラー
                    self.stopRecording()
                    onError(error)
                    return
                }
                                
                return
            }
            
            /// タイマー再設定
            makeFinishTimer(self.silenceTime)

            var isFinal = false
            if let result = result {
                // 結果に達したらisFinalがtrue
                isFinal = result.isFinal
                // 音声認識結果
                print("result:" + result.bestTranscription.formattedString)
                
                let substrings = result.bestTranscription.segments.map({$0.substring})
        
                self.onRecognition(substrings)
            }
            if isFinal { //録音タイムリミット
                print("recording time limit")
                // 録音停止
                self.stopRecording()
                inputNode.removeTap(onBus: 0)
            }
        }
        
        // 音声入力を監視
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { (buffer: AVAudioPCMBuffer, when: AVAudioTime) in
            // 音声認識のバッファに追加
            self.recognitionRequest?.append(buffer)
        }
        self.audioEngine.prepare()
        try self.audioEngine.start()
        
        print("Start Recording End")
    }
    
    /// 音声認識停止
    func stopRecording(){
        print("Stop Recording")
        
        // 既に停止済の場合、停止処理を行わない
        if status == .stop { return }
        // 録音停止
        status = .stop

        // タイマー停止
        timer?.invalidate()
        timer = nil
        
        // 音声認識の終了処理
        self.recognitionTask?.cancel()
        self.recognitionTask?.finish()
        self.recognitionTask = nil

        // AVAudioSessionの停止初期化
        self.audioEngine.inputNode.removeTap(onBus: 0)
        self.audioEngine.reset()
        self.audioEngine.stop()

        // 終了
        self.recognitionRequest?.endAudio()
        self.recognitionRequest = nil

        let audioSession = AVAudioSession.sharedInstance()
        do {
            // playAndRecordの場合、音量が小さいため、元に戻す
            try audioSession.setCategory(AVAudioSession.Category.playback)
            try audioSession.setMode(AVAudioSession.Mode.default)
        } catch{
            print("AVAudioSession error")
        }
        
        print("Stop Recording　End")
    }
    
    func cancelRecording(){
        print("Cancel Recording")
        
        // 前回処理分のクリア
        if recognitionTask != nil {
            recognitionTask?.cancel()
            recognitionTask = nil
        }
        audioEngine.reset()
        if self.recognitionRequest != nil {
            self.recognitionRequest?.endAudio()
            recognitionRequest = nil
        }
    }
    
    /// タイマー設定
    func makeFinishTimer(_ silenceTime:TimeInterval){
        self.silenceTime = silenceTime
        // 前のタイマーキル
        if let timer = timer{
            timer.invalidate()
        }
        /// タイマー再設定
        if silenceTime > 0 {
            print("makeFinishTimer silenceTime:\(silenceTime)")
            timer = Timer.scheduledTimer(timeInterval: silenceTime, target: self, selector: #selector(self.didFinishTalk), userInfo: nil, repeats: false)
        }
    }
    
    /// タイマーによる最初の終了処理
    @objc func firstFinishTalk() {
        print("firstFinishTalk")
        
        // Call Back
        onFirstFinishTask()
    }
    
    /// タイマーによる終了処理
    @objc func didFinishTalk() {
        print("didFinishTalk")
        // silenceTime 初期化
        self.silenceTime = self.initSilenceTime
        
        // Call Back
        onFinishTask()
    }
    
    // MARK: SFSpeechRecognizerDelegate
    //speechRecognizerが使用可能かどうかでボタンのisEnabledを変更する
    public func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        if available {
            print("SFSpeechRecognizer available")
        } else {
            print("SFSpeechRecognizer not available")
        }
    }
}
