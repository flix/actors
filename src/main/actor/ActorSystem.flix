///
/// An actor system is a type alias for a record that consists of four fields:
///
/// @field `actors`          that declares the actors in the system.
/// @field `startPolicy`     that describes the policy for how actors are started.
/// @field `restartPolicy`   that describes the policy for how actors are restarted if they crash.
/// @field `shutdownPolicy`  that describes the policy for how actors are stopped.
///
type alias ActorSystem = {
    actors: Map[Str, ActorBehavior],
    startPolicy: ActorPolicy,
    restartPolicy: ActorPolicy,
    shutdownPolicy: ActorPolicy
}

///
/// A running actor system is a type alias for a channel of actor events.
///
opaque type RunningActorSystem = Channel[SystemEvent]

///
/// An actor is identified by its mailbox
///
type alias ActorRef = Mailbox // TODO: Quentin: Maybe a name and a mailbox?

namespace ActorSystem {

    ///
    /// Returns an actor system with a empty configuration.
    ///
    pub def empty(): ActorSystem = {
        actors          = Map#{},
        startPolicy     = emptyStartPolicy(),
        shutdownPolicy  = emptyShutdownPolicy(),
        restartPolicy   = emptyRestartPolicy()
    }

    ///
    /// Returns the empty mailbox capacity.
    ///
    pub def emptyMailboxCapacity(): Int = 1000 * 1000

    enum InternalActorState {
      ///
      /// An actor that has not been started previously, and has no mailbox
      ///
      case NotStarted,
      ///
      /// An actor that has been started and been assigned a mailbox. The actor could be stopped or crashed now.
      ///
      case Started(State, ActorRef)
    }

  type alias ActorMap = {
    // The actors running
    map: Map[Str, (InternalActorState, ActorBehavior, Option[ActorBehavior])],
    // The log of all events that happened
    log: List[(Str, State, State, Instant)],
    // The actors that are currently restarting
    restarting: List[Str],
    // Actors that have been dynamically created, with their parent and category
    dynamicActors: List[(Str, Str, Str)]
  }

    ///
    /// Return the current state of the actors in the system, using the ActorState, Log, and Actor relations.
    ///
    def statesOfActors(s: ActorSystem, actors: ActorMap): ActorPolicy & Impure = {
      // Builds the ActorState relation
      let statesRel = Map.foldLeftWithKey((states, actorName, actor) ->
        let (internalState, _, _) = actor;
        match internalState {
          case NotStarted => states <+> #{ActorState(actorName, Stopped).}
          case Started(st, _) => states <+> #{ActorState(actorName, st).}
        }, #{}, actors.map);
      // Builds the Log relation
      let logRel = List.foldLeft((log, data) ->
        let (actorName, stateBefore, stateAfter, instant) = data;
        log <+> #{ Log(actorName, stateBefore, stateAfter, instant). },
        #{}, actors.log);
      // Builds the Actor relation
      let actorsRel = Set.foldLeft((rel, actor: Str) -> {
        rel <+> #{Actor(actor).} },
        #{}, Map.keysOf(s.actors));
      // Builds the Created and Category relations, and fills the Actor relation with dynamic actors
      let createdRel = List.foldLeft((rel, dyn) ->
        let (name, parent, category) = dyn;
        rel <+> #{ Actor(name). Created(parent, name). Category(name, category). },
        #{}, actors.dynamicActors);
      // Add the rule for the Sibling relation
      let sibling = #{Sibling(x, y) :- Actor(parent), Created(parent, x), Created(parent, y).};
      let rightNow = Instant.now();
      statesRel <+> logRel <+> actorsRel <+> createdRel <+> sibling <+> #{ Clock(rightNow). }
    }

  rel ActorsNotStopped()
  ///
  /// Checks that all the actors are in the Stopped state
  ///
  def allActorsStopped(state: ActorPolicy): Bool =
    !((solve (state <+> #{
      ActorsNotStopped() :- ActorState(_, InTransition).
      ActorsNotStopped() :- ActorState(_, Running).
      // Crashed actors are considered stopped
    })) |= ActorsNotStopped().)

  ///
  /// Starts an actor given its name, behavior, and mailbox. Returns the updated map of running actors
  ///
  def startActor(actors: ActorMap, control: Channel[SystemEvent], actorName: Str, behavior: ActorBehavior, mailbox: Channel[Message]): ActorMap & Impure = {
    // Create the process of the new actor
    spawn ({
        match behavior(RunningActorSystem(control), mailbox) {
            case Done =>
                // Notify on the control channel that the actor is done
                control <- ActorDone(actorName)
            case ResumableCrash(resumableBehavior, _) =>
                // Notify that the actor has crashed
                control <- ActorResumableCrash(actorName, resumableBehavior)
            case NonResumableCrash(_) =>
                // Notify that the actor has crashed
                control <- ActorNonResumableCrash(actorName)
        }
    });
    // The channel on which the actor will notify us that is has successfully initialized
    let readyChan = chan Ready 0;
    // Tell the actor to initialize
    mailbox <- Start(readyChan);
    spawn ({
      // Wait (on a different process) for the actor to fully initialize
      // TODO: what if the actor crashes before being ready? Should we use a timeout? For now we assume it can't crash.
      <- readyChan;
      // Then notify the actor system
      control <- ActorReady(actorName)
    });
    // Add the actor to the map of running actors. It is now in transition.
    { map = Map.insert(actorName, (Started(InTransition, mailbox), behavior, None), actors.map),
      log = match Map.get(actorName, actors.map) {
        case Some((Started(st, _), _, _)) => (actorName, st, InTransition, Instant.now())
        case _ => (actorName, Stopped, InTransition, Instant.now())
      } :: actors.log
    | actors }
  }

  ///
  /// Runs the shutdown policy of an actor system.
  /// Returns the updated actor map after one iteration of the policy, or None if the system should stop.
  ///
  def runShutdownPolicy(s: ActorSystem, actors: ActorMap, _control: Channel[SystemEvent], notifyChan: Channel[Unit]): Option[ActorMap] & Impure = {
    Console.printLine("[system] shutdown policy");
    let currentState = statesOfActors(s, actors);
    let (actors2, n) = fold Stop (actors, 0) ((actorName, acc) -> // TODO: Fold requires a pure function and this is not pure, hence all the casts.
      let (m, n) = acc; // m is the number of actors (really) stopped in this iteration
      // Console.printLine("[system] have to stop actor: " + actorName);

      match Map.get(actorName, m.map) {
        case Some((Started(Running, mailbox), _, _)) => {
          Console.printLine("!!!!! [system] sending stop to " + actorName);
         // Running, Stop => stop the actor
         mailbox <- Stop; // actor will terminate and will notify the actor system
         (m, n+1)
      } as & Pure

      case Some((Started(ResumablyCrashed, mailbox), behavior, resumableBehavior)) => {
          // ResumablyCrashed, Stop => change state to stopped
          Console.printLine("[system] setting crashed1 to stop: " + actorName);
        ({ map = Map.insert(actorName, (Started(Stopped, mailbox), behavior, resumableBehavior), m.map),
           log = (actorName, ResumablyCrashed, Stopped, Instant.now()) :: m.log
         | m}, n)
      } as & Pure

      case Some((Started(NonResumablyCrashed, mailbox), behavior, resumableBehavior)) => {
          // NonResumablyCrashed, Stop => change state to stopped
          Console.printLine("[system] setting crashed2 to stop: " + actorName);
        ({ map = Map.insert(actorName, (Started(Stopped, mailbox), behavior, resumableBehavior), m.map),
           log = (actorName, NonResumablyCrashed, Stopped, Instant.now()) :: m.log
         | m}, n)
      } as & Pure

      case _ => {
          Console.printLine("[system] non-case for : " + actorName);
          // Other cases are no-ops
          (m, n)
      } as & Pure
      }) (solve (s.restartPolicy<+> s.shutdownPolicy <+> currentState));
    if (n == 0 && allActorsStopped(currentState)) {
      Console.printLine("[system] fully stopped");
      // System fully stopped
      notifyChan <- (); // Notify the requester of the shutdown
      None
    } else {
      Console.printLine("[system] still some actors to terminate");
      // Some actors still have to be stopped
      Some(actors2)
    }
  }

  /// If an actor policy specifies multiple actions for the same actor then the final action is computed by join (which is symmetric)
  ///
  /// Start, Stop     => Start
  /// Restart, Stop   => Restart
  /// Restart, Start  => Restart
  /// Stop, Resume    => Resume
  /// Restart, Resume => Resume
  /// Start, Resume   => Resume
  /// x, x            => x
  ///

  enum ActorAction {
    case ActionResume,
    case ActionStart,
    case ActionRestart,
    case ActionStop
  }
  def runRestartPolicy(s: ActorSystem, actors: ActorMap, control: Channel[SystemEvent]): ActorMap & Impure = {
    let currentState = statesOfActors(s, actors);
    // We just accumulate for each actor, whether it should 1. Stop, 2. Start, 3. Resume, overriding any previous value. This corresponds to the increasing order of the sop/start/resume lattice.
    let m0: Map[Str, ActorAction] = Map#{};
    let policy = solve (s.startPolicy <+> s.restartPolicy <+> currentState);
    // The order of the following folds are important: the later folds will take precedence over the previous ones in case multiple state changes for the same actor are requested by the policy.
    let m1 = fold Stop m0 ((actorName, m) -> Map.insert(actorName, ActionStop, m)) policy;
    let m2 = fold Start m1 ((actorName, m) -> Map.insert(actorName, ActionStart, m)) policy;
    let m3 = fold Restart m2 ((actorName, m) -> Map.insert(actorName, ActionRestart, m)) policy;
    let m4 = fold Resume m3 ((actorName, m) -> Map.insert(actorName, ActionResume, m)) policy;
    // Then, we just apply the action for each actor, according to the table.
    Map.foldLeftWithKey((m, actorName, action) ->
      match action {
      case ActionStart => match Map.get(actorName, m.map) {
          case Some((NotStarted, behavior, _)) =>
            // Start the actor with a new mailbox
            let mailbox = chan Message emptyMailboxCapacity();
            startActor(m, control, actorName, behavior, mailbox)
          case Some((Started(Stopped, mailbox), behavior, _)) =>
            // Start the actor, reusing the mailbox
            startActor(m, control, actorName, behavior, mailbox)
          case Some((Started(ResumablyCrashed, mailbox), behavior, _)) =>
            // Start the actor with the initial state, but reusing the mailbox
            startActor(m, control, actorName, behavior, mailbox)
          case Some((Started(NonResumablyCrashed, mailbox), behavior, _)) =>
            // Start the actor with the initial state, reusing the mailbox
            startActor(m, control, actorName, behavior, mailbox)
          case _ =>
            // No-op
            m
      }
      case ActionRestart => match Map.get(actorName, m.map) {
          case Some((Started(Running, mailbox), _, _)) =>
            // If the actor is running, stop it first
            mailbox <- Stop;
            // Remember that the actor has to be restarted after it successfully stopped
            { restarting = actorName :: m.restarting | m }
          case Some((Started(Stopped, mailbox), behavior, _)) =>
            startActor(m, control, actorName, behavior, mailbox)
          case Some((Started(ResumablyCrashed, mailbox), behavior, _)) =>
            // Start the actor from a fresh initial state, ignores the resumable behavior
            startActor(m, control, actorName, behavior, mailbox)
          case Some((Started(NonResumablyCrashed, mailbox), behavior, _)) =>
            startActor(m, control, actorName, behavior, mailbox)
          case _ =>
            // No-op
            // TODO: is that correct? This is only for the case of an actor that hasn't been started, hence "restarting" it does not really make sense
            m
      }
      case ActionResume => match Map.get(actorName, m.map) {
          case Some((Started(Stopped, mailbox), behavior, _)) =>
            // Start the actor with the initial state, reusing the mailbox
            startActor(m, control, actorName, behavior, mailbox)
          case Some((Started(ResumablyCrashed, mailbox), behavior, resumableBehavior)) =>
            startActor(m, control, actorName, Option.getWithDefault(resumableBehavior, behavior), mailbox)
          case Some((Started(NonResumablyCrashed, mailbox), behavior, _)) =>
            // Start the actor with initial state
            startActor(m, control, actorName, behavior, mailbox)
          case _ =>
            // No-op
            m
      }
      case ActionStop => match Map.get(actorName, m.map) {
          case Some((Started(Running, mailbox), _, _)) =>
            // Stop the actor
            mailbox <- Stop; // actor will terminate and will notify the actor system
            m
          case Some((Started(ResumablyCrashed, mailbox), behavior, resumableBehavior)) =>
            // Change the state of the crashed actor to stopped
            { map = Map.insert(actorName, (Started(Stopped, mailbox), behavior, resumableBehavior), m.map),
              log = (actorName, ResumablyCrashed, Stopped, Instant.now()) :: m.log
            | m }
          case Some((Started(NonResumablyCrashed, mailbox), behavior, resumableBehavior)) =>
            // Change the state of the crashed actor to stopped
            { map = Map.insert(actorName, (Started(Stopped, mailbox), behavior, resumableBehavior), m.map),
              log = (actorName, NonResumablyCrashed, Stopped, Instant.now()) :: m.log
            | m }
          case _ =>
            // No-op
            m
      }
    }, actors, m4)
  }

  enum Policy {
    case PolicyNotStarted, // Not started yet
    case PolicyRunning, // Fully running
    case PolicyStopping(Channel[Unit]) // Currently stopping, with the channel to notify when everything has safely stopped
  }

  ///
  /// Restart all actors that are "restarting" (have been send a Stop signal) and have successfully stopped or crashed.
  ///
  def startRestartingActors(actors: ActorMap, control: Channel[SystemEvent]): ActorMap & Impure = {
    let (actors2, restarting) = List.foldLeft((acc, actorName) ->
      let (m, notRestarted) = acc;
      match Map.get(actorName, m.map) {
        case Some((Started(Stopped, mailbox), behavior, _)) =>
          // The actor successfully stopped, start it again
          (startActor(m, control, actorName, behavior, mailbox), notRestarted)
        case Some((Started(ResumablyCrashed, mailbox), behavior, _)) =>
          // The actor crashed (probably when stopping), start it again
          (startActor(m, control, actorName, behavior, mailbox), notRestarted)
        case Some((Started(NonResumablyCrashed, mailbox), behavior, _)) =>
          // The actor crashed (probably when stopping), start it again
          (startActor(m, control, actorName, behavior, mailbox), notRestarted)
        case _ =>
          // The actor is stil running, don't start it now.
          (m, actorName :: notRestarted)
      }, (actors, Nil), actors.restarting);
    // Only keep actors that have not been restarted as "restarting" actors
    { restarting = restarting | actors2 }
  }

  ///
  /// Run the current policy (@param `policy`). Returns the updated actor map, as well as the next state of the policy.
  ///
  def runPolicy(s: ActorSystem, actors: ActorMap, control: Channel[SystemEvent], policy: Policy): Option[(ActorMap, Policy)] & Impure = {
    let r = match policy {
      case PolicyNotStarted => Some((actors, policy))
      case PolicyRunning => Some((runRestartPolicy(s, actors, control), PolicyRunning))
      case PolicyStopping(c) => Option.map((a) -> (a, PolicyStopping(c)), runShutdownPolicy(s, actors, control, c))
    };
    // Restart the actors that have to be restarted
    Option.map(res -> (startRestartingActors(fst(res), control), snd(res)), r)
  }

  def runPolicyAndRecurse(s: ActorSystem, actors: ActorMap, control: Channel[SystemEvent], policy: Policy): Unit & Impure =
    match runPolicy(s, actors, control, policy) {
      case Some((actors2, policy2)) => actorSystem(s, actors2, control, policy2)
      case None => ()
    }

  ///
  /// The main loop of the actor system, handling messages over the control channel
  ///
  def actorSystem(s: ActorSystem, actors: ActorMap, control: Channel[SystemEvent], policy: Policy): Unit & Impure = select {
      case event <- control => match event {
        case SystemStart =>
          //assert!(policy == PolicyNotStarted); // Otherwise, the actor system has been started more than once.
          runPolicyAndRecurse(s, actors, control, PolicyRunning)
        case SystemShutdown(c) =>
          runPolicyAndRecurse(s, actors, control, PolicyStopping(c))
        case SendMessage(actorName, msg, c) =>
          match Map.get(actorName, actors.map) {
            case Some((Started(Running, mailbox), _, _)) =>
              mailbox <- msg;
              c <- true
            case Some(_) => c <- false // Actor not running
            case _ => c <- false // Actor not found
          };
          // We don't run the policy here because that's an external event and had no way of making the actor system progress.
          actorSystem(s, actors, control, policy)
        case GetActor(actorName, c) =>
          let mb = Option.flatMap(act -> match act {
            case (Started(st, mailbox), _, _) =>
              Some(mailbox)
            case _ => None
          }, Map.get(actorName, actors.map));
          c <- mb;
          actorSystem(s, actors, control, policy)
        case CreateActor(parent, beh, category, replyChan) =>
          import java.time.Instant.toString();
          import java.time.Instant:now();
          let mailbox = chan Message emptyMailboxCapacity();
          let actorName = category + (toString(now()));
          let actors2 = startActor(actors, control, actorName, beh, mailbox);
          let actors3 = { dynamicActors = (actorName, parent, category) :: actors2.dynamicActors | actors2 };
          replyChan <- mailbox;
          runPolicyAndRecurse(s, actors3, control, policy)
        case ActorReady(actorName) =>
          let actors2 = match Map.get(actorName, actors.map) {
            case Some((Started(InTransition, mailbox), behavior, resumableBehavior)) =>
              // The actor has initialized and is now running
              { map = Map.insert(actorName, (Started(Running, mailbox), behavior, resumableBehavior), actors.map),
                log = (actorName, InTransition, Running, Instant.now()) :: actors.log
              | actors }
            case _ =>
              // Ignore ready message if the actor is not in transition, there probably has been a race that we can safely ignore
              actors
          };
          runPolicyAndRecurse(s, actors2, control, policy)
        case ActorDone(actorName) =>
          let actors2 = match Map.get(actorName, actors.map) {
            case Some((Started(Running, mailbox), behavior, resumableBehavior)) =>
              { map = Map.insert(actorName, (Started(Stopped, mailbox), behavior, resumableBehavior), actors.map),
                log = (actorName, Running, Stopped, Instant.now()) :: actors.log
              | actors }
            case _ =>
              // TODO: When do these other case happen? If the actor is done, it should not be in any other state than started.
              ???
          };
          runPolicyAndRecurse(s, actors2, control, policy)
        case ActorResumableCrash(actorName, resumableBehavior) =>
          let actors2 = match Map.get(actorName, actors.map) {
            case Some((Started(st, mailbox), behavior, _)) =>
              { map = Map.insert(actorName, (Started(ResumablyCrashed, mailbox), behavior, Some(resumableBehavior)), actors.map),
                log = (actorName, st, ResumablyCrashed, Instant.now()) :: actors.log
              | actors }
            case _ =>
              // TODO: actor should only crash if it was running before
              // TODO: what about InTransition? An actor could crash while initializing
              ???
          };
          runPolicyAndRecurse(s, actors2, control, policy)
        case ActorNonResumableCrash(actorName) =>
          let actors2 = match Map.get(actorName, actors.map) {
            case Some((Started(st, mailbox), behavior, resumableBehavior)) =>
              { map = Map.insert(actorName, (Started(NonResumablyCrashed, mailbox), behavior, resumableBehavior), actors.map),
                log = (actorName, st, NonResumablyCrashed, Instant.now()) :: actors.log
              | actors }
            case _ =>
              // TODO: same as for resumable crash
              ???
          };
          runPolicyAndRecurse(s, actors2, control, policy)
      }
      case _ <- Timer.seconds(1i64) =>
        // Run the policy every second if nothing else happened
        runPolicyAndRecurse(s, actors, control, policy)
    }

    ///
    /// Starts the given actor system `s`. Returns the updated actor system
    ///
    pub def start(s: ActorSystem): RunningActorSystem & Impure = {
      let control = chan SystemEvent 10;
      let actors = Map.foldLeftWithKey((m, actorName, behavior) ->
        Map.insert(actorName, (NotStarted, behavior, None), m),
        Map#{}, s.actors);
      spawn (actorSystem(s, { map = actors, log = Nil, restarting = Nil, dynamicActors = Nil }, control, PolicyNotStarted));
      control <- SystemStart;
      RunningActorSystem(control)
    }

    ///
    /// Composes two actor systems into a single one, if they can be joined.
    /// Names of actors in both systems have to be distinct.
    /// Policies are joined, which might not be what you want. In that case, it is a good idea to redefine the policies that have to be, after composing the systems.
    ///
  pub def compose(s1: ActorSystem, s2: ActorSystem): Option[ActorSystem] =
    if (Map.isEmpty(Map.intersection(s1.actors, s2.actors))) {
      // No shared names, we can join
      Some ({
        actors = Map.unionWith((v1, _) -> v1 /* should never be called */, s1.actors, s2.actors),
        startPolicy = s1.startPolicy <+> s2.startPolicy,
        restartPolicy = s1.restartPolicy <+> s2.restartPolicy,
        shutdownPolicy = s1.shutdownPolicy <+> s2.shutdownPolicy
      })
    } else {
      // There are some names shared so we can't join the systems
      None
    }

    ///
    /// Initiates a shutdown of the given actor system `s` and waits for its orderly shutdown.
    ///
  pub def shutdown(s: RunningActorSystem): Unit & Impure = {
        let RunningActorSystem(sys) = s;
        let c = chan Unit 0;
        sys <- SystemShutdown(c);
        <- c
  }
}

