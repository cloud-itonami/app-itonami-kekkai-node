import Dispatch
import NetworkExtension

func main() -> Never {
    autoreleasepool {
        NEProvider.startSystemExtensionMode()
        KekkaiSystemExtensionXPCService.shared.start()
    }
    dispatchMain()
}

main()
