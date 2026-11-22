import common from '@ohos.app.ability.common';
import { webview } from '@kit.ArkWeb';
import { FlutterPage } from '@ohos/flutter_ohos'
import { rtcHost, RtcPageSink } from '../plugins/OhosWebRtcPlugin';

let storage = LocalStorage.getShared()
const EVENT_BACK_PRESS = 'EVENT_BACK_PRESS'
const RTC_DOCUMENT = 'resource://rawfile/dsh-rtc.html';

@Entry(storage)
@Component
struct Index {
  private context = getContext(this) as common.UIAbilityContext
  @LocalStorageLink('viewId') viewId: string = "";
  @State private rtcMounted: boolean = false;
  private rtcController: webview.WebviewController = new webview.WebviewController();
  private rtcSink: RtcPageSink = new RtcPageSink();

  aboutToAppear(): void {
    rtcHost.mount = (visible: boolean): void => { this.rtcMounted = visible; };
  }

  aboutToDisappear(): void {
    rtcHost.mount = undefined;
    rtcHost.reset();
  }

  build() {
    Stack() {
      FlutterPage({ viewId: this.viewId })
      if (this.rtcMounted) {
        Web({ src: $rawfile('dsh-rtc.html'), controller: this.rtcController })
          .javaScriptAccess(true)
          .fileAccess(false)
          .domStorageAccess(false)
          .mixedMode(MixedMode.None)
          .multiWindowAccess(false)
          .javaScriptProxy({ object: this.rtcSink, name: 'dshRtcSink', methodList: ['complete', 'event'],
            controller: this.rtcController })
          .onLoadIntercept((event: OnLoadInterceptEvent): boolean => event.data.getRequestUrl() !== RTC_DOCUMENT)
          .onPageEnd((): void => rtcHost.ready(this.rtcController))
          .onRenderExited((): void => rtcHost.reset())
          .width(1).height(1).opacity(0).focusable(false).hitTestBehavior(HitTestMode.None)
      }
    }.width('100%').height('100%')
  }

  onBackPress(): boolean {
    this.context.eventHub.emit(EVENT_BACK_PRESS)
    return true
  }
}
