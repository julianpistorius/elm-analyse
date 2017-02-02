module Analyser.Checks.UnusedVariable exposing (scan)

import AST.Types exposing (File, Lambda, RecordUpdate, LetBlock, Function, VariablePointer, Declaration(FuncDecl, AliasDecl, DestructuringDeclaration, TypeDecl, PortDeclaration, InfixDeclaration), Case, Pattern(TuplePattern, RecordPattern, ListPattern, UnConsPattern, VarPattern, NamedPattern, AsPattern, ParentisizedPattern), OperatorApplication, Module(EffectModule))
import AST.Ranges exposing (Range, emptyRange)
import Analyser.FileContext exposing (FileContext)
import Interfaces.Interface as Interface
import Analyser.Messages exposing (Message(UnusedVariable, UnusedTopLevel))
import Dict exposing (Dict)
import Inspector exposing (defaultConfig, Action(Inner, Pre, Post))
import Tuple2
import Analyser.Checks.Variables exposing (getTopLevels, patternToVars, getDeclarationsVars)


type alias Scope =
    Dict String ( Int, Range )


type alias ActiveScope =
    ( List String, Scope )


type alias UsedVariableContext =
    { poppedScopes : List Scope
    , activeScopes : List ActiveScope
    }


scan : FileContext -> List Message
scan fileContext =
    let
        x : UsedVariableContext
        x =
            Inspector.inspect
                { defaultConfig
                    | onFile = Pre onFile
                    , onFunction = Inner onFunction
                    , onLetBlock = Inner onLetBlock
                    , onLambda = Inner onLambda
                    , onCase = Inner onCase
                    , onOperatorApplication = Post onOperatorAppliction
                    , onFunctionOrValue = Post onFunctionOrValue
                    , onRecordUpdate = Post onRecordUpdate
                }
                fileContext.ast
                emptyContext

        onlyUnused : List ( String, ( Int, Range ) ) -> List ( String, ( Int, Range ) )
        onlyUnused =
            List.filter (Tuple.second >> Tuple.first >> (==) 0)

        unusedVariables =
            x.poppedScopes
                |> List.concatMap Dict.toList
                |> onlyUnused
                |> List.map (\( x, ( _, y ) ) -> UnusedVariable fileContext.path x y)

        unusedTopLevels =
            x.activeScopes
                |> List.head
                |> Maybe.map Tuple.second
                |> Maybe.withDefault (Dict.empty)
                |> Dict.toList
                |> onlyUnused
                |> List.filter (filterByModuleType fileContext)
                |> List.filter (Tuple.first >> flip Interface.doesExposeFunction fileContext.interface >> not)
                |> List.map (\( x, ( _, y ) ) -> UnusedTopLevel fileContext.path x y)
    in
        unusedVariables ++ unusedTopLevels


filterByModuleType : FileContext -> ( String, ( Int, Range ) ) -> Bool
filterByModuleType fileContext =
    case fileContext.ast.moduleDefinition of
        EffectModule _ ->
            filterForEffectModule

        _ ->
            (always True)


filterForEffectModule : ( String, ( Int, Range ) ) -> Bool
filterForEffectModule ( k, _ ) =
    not <| List.member k [ "init", "onEffects", "onSelfMsg", "subMap", "cmdMap" ]


pushScope : List VariablePointer -> UsedVariableContext -> UsedVariableContext
pushScope vars x =
    let
        y : ActiveScope
        y =
            vars
                |> List.map (\x -> ( x.value, ( 0, x.range ) ))
                |> Dict.fromList
                |> (,) []
    in
        { x | activeScopes = y :: x.activeScopes }


popScope : UsedVariableContext -> UsedVariableContext
popScope x =
    { x
        | activeScopes = List.drop 1 x.activeScopes
        , poppedScopes =
            List.head x.activeScopes
                |> Maybe.map
                    (\( _, activeScope ) ->
                        if Dict.isEmpty activeScope then
                            x.poppedScopes
                        else
                            activeScope :: x.poppedScopes
                    )
                |> Maybe.withDefault x.poppedScopes
    }


emptyContext : UsedVariableContext
emptyContext =
    { poppedScopes = [], activeScopes = [] }


unMaskVariable : String -> UsedVariableContext -> UsedVariableContext
unMaskVariable k context =
    { context
        | activeScopes =
            case context.activeScopes of
                [] ->
                    []

                ( masked, vs ) :: xs ->
                    ( List.filter ((/=) k) masked, vs ) :: xs
    }


maskVariable : String -> UsedVariableContext -> UsedVariableContext
maskVariable k context =
    { context
        | activeScopes =
            case context.activeScopes of
                [] ->
                    []

                ( masked, vs ) :: xs ->
                    ( k :: masked, vs ) :: xs
    }


flagVariable : String -> List ActiveScope -> List ActiveScope
flagVariable k l =
    case l of
        [] ->
            []

        ( masked, x ) :: xs ->
            if List.member k masked then
                ( masked, x ) :: xs
            else if Dict.member k x then
                ( masked, (Dict.update k (Maybe.map (Tuple2.mapFirst ((+) 1))) x) ) :: xs
            else
                ( masked, x ) :: flagVariable k xs


addUsedVariable : String -> UsedVariableContext -> UsedVariableContext
addUsedVariable x context =
    { context | activeScopes = flagVariable x context.activeScopes }


onFunctionOrValue : String -> UsedVariableContext -> UsedVariableContext
onFunctionOrValue x context =
    addUsedVariable x context


onRecordUpdate : RecordUpdate -> UsedVariableContext -> UsedVariableContext
onRecordUpdate recordUpdate context =
    addUsedVariable recordUpdate.name context


onOperatorAppliction : OperatorApplication -> UsedVariableContext -> UsedVariableContext
onOperatorAppliction operatorApplication context =
    addUsedVariable operatorApplication.operator context


onFile : File -> UsedVariableContext -> UsedVariableContext
onFile file context =
    getTopLevels file
        |> flip pushScope context


onFunction : (UsedVariableContext -> UsedVariableContext) -> Function -> UsedVariableContext -> UsedVariableContext
onFunction f function context =
    let
        preContext =
            context
                |> maskVariable function.declaration.name.value
                |> \c -> function.declaration.arguments |> List.concatMap patternToVars |> flip pushScope c

        postContext =
            f preContext
    in
        postContext
            |> popScope
            |> unMaskVariable function.declaration.name.value


onLambda : (UsedVariableContext -> UsedVariableContext) -> Lambda -> UsedVariableContext -> UsedVariableContext
onLambda f lambda context =
    let
        preContext =
            lambda.args
                |> List.concatMap patternToVars
                |> flip pushScope context

        postContext =
            f preContext
    in
        postContext |> popScope


onLetBlock : (UsedVariableContext -> UsedVariableContext) -> LetBlock -> UsedVariableContext -> UsedVariableContext
onLetBlock f letBlock context =
    letBlock.declarations
        |> getDeclarationsVars
        |> flip pushScope context
        |> f
        |> popScope


onCase : (UsedVariableContext -> UsedVariableContext) -> Case -> UsedVariableContext -> UsedVariableContext
onCase f caze context =
    let
        preContext =
            Tuple.first caze
                |> patternToVars
                |> flip pushScope context

        postContext =
            f preContext
    in
        postContext |> popScope
