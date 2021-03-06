import Foundation
import libc

public class SocketServer: ServerDriver {
    
    /// Turns received `Request`s into a `Response`s
    public var delegate: ServerDriverDelegate?
    
    init() {
        
    }
    
    /**
        Starts the server on a given port.
     
        - parameter port: The port to listen on.
     */
    public func boot(ip ip: String, port: Int) throws {
        //stop the server if it's running
        self.halt()
        
        //open a socket, might fail
        self.listenSocket = try Socket.tcpSocketForListen(ip, port: UInt16(port))

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0)) {
            
            //creates the infinite loop that will wait for client connections
            while let socket = try? self.listenSocket.acceptClientSocket() {
                
                //wait for lock to notify a new connection
                self.clientSocketsLock.locked {
                    //keep track of open sockets
                    self.clientSockets.insert(socket)
                }
                
                //handle connection in background thread
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), {
                    self.handleConnection(socket)
                    
                    //set lock to wait for another connection
                    self.clientSocketsLock.locked {
                        self.clientSockets.remove(socket)
                    }
                })
            }
            
            //stop the server in case something didn't work
            self.halt()
        }

    }
    
    /**
        Stops the server by closing all connected 
        client `Socket`s
    */
    public func halt() {
        //free the port
        self.listenSocket.release()
        
        //shutdown all client sockets
        self.clientSocketsLock.locked {
            for socket in self.clientSockets {
                socket.shutdwn()
            }
            self.clientSockets.removeAll(keepCapacity: true)
        }
    }
    
    ///A `Socket` open to the port the server is listening on. Usually 80.
    private var listenSocket: Socket = Socket(socketFileDescriptor: -1)

    ///A set of connected client `Socket`s.
    private var clientSockets: Set<Socket> = []

    ///The shared lock for notifying new connections.
    private let clientSocketsLock = NSLock()
   
    /**
        Handles incoming `Socket` connections by parsing
        the HTTP request into a `Request` and writing
        a `Response` back to the `Socket`.
    */
    func handleConnection(socket: Socket) {
        defer {
            socket.release()
        }
        
        guard let delegate = self.delegate else {
            print("No server delegate")
            return
        }
        
        let parser = SocketParser()

        while let request = try? parser.readHttpRequest(socket) {
            let response = delegate.serverDriverDidReceiveRequest(request)

            var keepConnection = request.supportsKeepAlive
            do {
                keepConnection = try self.respond(socket, response: response, keepAlive: keepConnection)
            } catch {
                print("Failed to send response: \(error)")
                break
            }
            if !keepConnection { break }
        }

    }
    
    /**
        Writes the `Response` to the client `Socket`.
    */
    private func respond(socket: Socket, response: Response, keepAlive: Bool) throws -> Bool {
        if let response = response as? AsyncResponse {
            try response.writer(socket)
        } else {
            try socket.write("HTTP/1.1 \(response.status.code) \(response.status)\r\n")

            var headers = response.headers

            if response.data.count >= 0 {
                headers["Content-Length"] = "\(response.data.count)"
            }
            
            if keepAlive && response.data.count != -1 {
                headers["Connection"] = "keep-alive"
            }
            
            for (name, value) in headers {
                try socket.write("\(name): \(value)\r\n")
            }
            
            try socket.write("\r\n")

            try socket.write(response.data)
        }
        
        return keepAlive && response.data.count != -1;  
    }
}
