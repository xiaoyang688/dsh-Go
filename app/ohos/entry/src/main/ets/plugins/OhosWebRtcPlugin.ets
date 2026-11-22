import { webview } from '@kit.ArkWeb';
import { FlutterPlugin, FlutterPluginBinding, MethodCall, MethodCallHandler, MethodChannel,
  MethodResult } from '@ohos/flutter_ohos';

const METHODS: string[] = ['create', 'createOffer', 'setAnswer', 'addIceCandidate', 'send', 'stats', 'close'];
interface PeerArgs { id: string; }
interface PeerEvent extends PeerArgs { type: string; reason?: string; }
interface Pending { id: string; method: string; result: MethodResult; timer: number; }

// One page per Flutter host. The page is mounted on the first connection attempt.
// It only receives allowlisted method names and JSON-quoted data. No caller-supplied script/URL.
class RtcHost {
  channel?: MethodChannel;
  mount?: (visible: boolean) => void;
  private controller?: webview.WebviewController;
  private creates: Map<number, string> = new Map();
  private pending: Map<number, Pending> = new Map();
  private peers: Set<string> = new Set();
  private sequence: number = 0;

  ready(controller: webview.WebviewController): void {
    this.controller = controller;
    this.creates.forEach((args: string, ticket: number): void => this.dispatch(ticket, 'create', args));
    this.creates.clear();
  }

  reset(): void {
    const controller = this.controller;
    this.controller = undefined;
    this.mount?.(false);
    this.creates.clear();
    this.pending.forEach((_call: Pending, ticket: number): void => this.complete(ticket, false, ''));
    this.peers.forEach((id: string): void => {
      const event: PeerEvent = {id: id, type: 'closed', reason: 'WebRTC page closed'};
      this.channel?.invokeMethod('event', JSON.stringify(event));
    });
    this.peers.clear();
    // Removing the Web component also disposes its peers when its renderer is gone.
    if (controller) {
      try { controller.runJavaScript('window.dshRtcCloseAll()').catch((): void => {}); } catch (_) {}
    }
  }

  event(json: string): void {
    const event = JSON.parse(json) as PeerEvent;
    if (!this.peers.has(event.id)) return;
    if (event.type === 'closed') this.peers.delete(event.id);
    this.channel?.invokeMethod('event', json);
  }

  complete(ticket: number, success: boolean, value: string): void {
    const call = this.pending.get(ticket);
    if (!call) return;
    this.pending.delete(ticket);
    this.creates.delete(ticket);
    clearTimeout(call.timer);
    if (success) {
      if (call.method === 'create') this.peers.add(call.id);
      if (call.method === 'close') this.peers.delete(call.id);
      call.result.success(call.method === 'stats' || call.method === 'createOffer' ? value : null);
    } else {
      call.result.error('rtc_unavailable', 'WebRTC operation failed: ' + call.method, null);
    }
  }

  call(call: MethodCall, result: MethodResult): void {
    if (!METHODS.includes(call.method)) { result.notImplemented(); return; }
    const args: Object | null = call.args;
    if (typeof args !== 'string') { result.error('rtc_arguments', 'Expected peer arguments', null); return; }
    let id: string;
    try { id = (JSON.parse(args) as PeerArgs).id; } catch (_) { id = ''; }
    if (typeof id !== 'string' || !id) { result.error('rtc_arguments', 'Missing peer ID', null); return; }
    if (!this.controller && (call.method !== 'create' || !this.mount)) {
      if (call.method === 'close') result.success(null);
      else result.error('rtc_unavailable', 'WebRTC page unavailable', null);
      return;
    }
    const ticket = ++this.sequence;
    const timer = setTimeout((): void => {
      // A lost create acknowledgement can leave a live browser peer. Retire its page.
      if (call.method === 'create') this.reset();
      else this.complete(ticket, false, '');
    }, 5000);
    this.pending.set(ticket, {id: id, method: call.method, result: result, timer: timer});
    if (!this.controller) {
      this.creates.set(ticket, args);
      this.mount?.(true);
    } else this.dispatch(ticket, call.method, args);
  }

  private dispatch(ticket: number, method: string, json: string): void {
    const script = 'window.dshRtcCommand(' + ticket + ',' + JSON.stringify(method) + ',' + JSON.stringify(json) + ')';
    try {
      this.controller!.runJavaScript(script).catch((): void => this.complete(ticket, false, ''));
    } catch (_) { this.complete(ticket, false, ''); }
  }
}
export const rtcHost = new RtcHost();

// Expose only these two callbacks to the bundled local document.
export class RtcPageSink {
  complete(ticket: number, success: boolean, value: string): void { rtcHost.complete(ticket, success, value); }
  event(json: string): void { rtcHost.event(json); }
}

export default class OhosWebRtcPlugin implements FlutterPlugin, MethodCallHandler {
  getUniqueClassName(): string { return 'DshOhosWebRtcPlugin'; }
  onAttachedToEngine(binding: FlutterPluginBinding): void {
    rtcHost.channel = new MethodChannel(binding.getBinaryMessenger(), 'dsh/ohos-webrtc');
    rtcHost.channel.setMethodCallHandler(this);
  }
  onMethodCall(call: MethodCall, result: MethodResult): void { rtcHost.call(call, result); }
  onDetachedFromEngine(_binding: FlutterPluginBinding): void {
    rtcHost.reset();
    rtcHost.channel?.setMethodCallHandler(null);
    rtcHost.channel = undefined;
  }
}
