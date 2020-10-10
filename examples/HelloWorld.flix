/// ///
/// /// An actor system with a single actor that prints hello and goodbye.
/// ///
/// namespace HelloWorld {

///     ///
///     /// The main entry point for the single actor system.
///     ///
///     @test
///     pub def main(): Unit =
///         let sys = ActorSystem.start(system());
///         <- Timer.milliseconds(100i64);
///         ActorSystem.shutdown(sys)

///     ///
///     /// Returns an actor system with one hello world actor.
///     ///
///     pub def system(): ActorSystem = {
///         let empty = ActorSystem.empty();
///         let actors = Map#{
///             "helloWorld" -> helloWorld
///         };
///         { actors = actors | empty }
///     }

///     ///
///     /// An actor that prints hello world and then terminates.
///     ///
///     pub def helloWorld(dir: ActorDirectory, mailbox: Mailbox): ActorResult[Str] =
///         match <- mailbox {
///             case Start(c) =>
///                 Console.printLine("Hello World!");
///                 c <- Ready;
///                 helloWorld(dir, mailbox)
///             case Stop =>
///                 Console.printLine("Goodbye World!");
///                 Done
///             case Msg(msg, _) => ResumableCrash(helloWorld, "Unexpected message: " + msg)
///         }

/// }
