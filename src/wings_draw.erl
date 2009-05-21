%%
%%  wings_draw.erl --
%%
%%     This module draws objects using OpenGL.
%%
%%  Copyright (c) 2001-2009 Bjorn Gustavsson
%%
%%  See the file "license.terms" for information on usage and redistribution
%%  of this file, and for a DISCLAIMER OF ALL WARRANTIES.
%%
%%     $Id$
%%

-module(wings_draw).
-export([refresh_dlists/1,
	 invalidate_dlists/1,
	 update_sel_dlist/0,
	 changed_we/2,
	 split/3,original_we/1,update_dynamic/2,join/1,abort_split/1,
	 face_ns_data/1]).

% export for plugins that need to draw stuff
-export([drawVertices/2]).

-define(NEED_OPENGL, 1).
-define(NEED_ESDL, 1).
-include("wings.hrl").
-include("e3d.hrl").

-import(lists, [foreach/2,reverse/1,reverse/2,member/2,
		foldl/3,sort/1,keysort/2]).

-record(split,
	{static_vs,
	 dyn_vs,
	 dyn_plan,				%Plan for drawing dynamic faces.
	 orig_ns,
	 orig_we
	}).

%%%
%%% Refresh the display lists from the contents of St.
%%%
%%% Invisible objects no longer have any #dlo{} entries.
%%%

refresh_dlists(St) ->
    invalidate_dlists(St),
    build_dlists(St),
    update_sel_dlist().

invalidate_dlists(#st{selmode=Mode,sel=Sel}=St) ->
    prepare_dlists(St),
    case wings_dl:changed_materials(St) of
	[] -> ok;
	ChangedMat -> invalidate_by_mat(ChangedMat)
    end,
    wings_dl:map(fun(D0, Data) ->
			 D = update_mirror(D0),
			 invalidate_sel(D, Data, Mode)
		 end, Sel),
    update_needed(St).

prepare_dlists(#st{shapes=Shs}) ->
    wings_dl:update(fun(D, A) ->
			    prepare_fun(D, A)
		    end, gb_trees:values(Shs)).

prepare_fun(eol, [#we{perm=Perm}|Wes]) when ?IS_NOT_VISIBLE(Perm) ->
    prepare_fun(eol, Wes);
prepare_fun(eol, [We|Wes]) ->
    D = #dlo{src_we=We,open=wings_we:any_hidden(We)},
    {changed_we(D, D),Wes};
prepare_fun(eol, []) ->
    eol;
prepare_fun(#dlo{src_we=#we{id=Id}},
	    [#we{id=Id,perm=Perm}|Wes]) when ?IS_NOT_VISIBLE(Perm) ->
    {deleted,Wes};
prepare_fun(#dlo{}=D, [#we{perm=Perm}|Wes]) when ?IS_NOT_VISIBLE(Perm) ->
    prepare_fun(D, Wes);
prepare_fun(#dlo{src_we=We,split=#split{}=Split}=D, [We|Wes]) ->
    {D#dlo{src_we=We,split=Split#split{orig_we=We}},Wes};

prepare_fun(#dlo{src_we=We}=D, [We|Wes]) ->
    %% No real change - take the latest We for possible speed-up
    %% of further comparisons.
    {D#dlo{src_we=We},Wes};

prepare_fun(#dlo{src_we=#we{id=Id}}=D, [#we{id=Id}=We1|Wes]) ->
    prepare_fun_1(D, We1, Wes);

prepare_fun(#dlo{}, Wes) ->
    {deleted,Wes}.

prepare_fun_1(#dlo{src_we=#we{perm=Perm0}=We0}=D, #we{perm=Perm1}=We, Wes) ->
    case only_permissions_changed(We0, We) of
	true ->
	    %% More efficient, and prevents an object from disappearing
	    %% if lockness was toggled while inside a secondary selection.
	    case {Perm0,Perm1} of
		{0,1} -> {D#dlo{src_we=We,pick=none},Wes};
		{1,0} -> {D#dlo{src_we=We,pick=none},Wes};
		_ -> prepare_fun_2(D, We, Wes)
	    end;
	false -> prepare_fun_2(D, We, Wes)
    end.

prepare_fun_2(#dlo{proxy_data=Proxy,ns=Ns}=D, We, Wes) ->
    Open = wings_we:any_hidden(We),
    {changed_we(D, #dlo{src_we=We,open=Open,
			mirror=none,proxy_data=Proxy,ns=Ns}),Wes}.

only_permissions_changed(#we{perm=P}, #we{perm=P}) -> false;
only_permissions_changed(We0, We1) -> We0#we{perm=0} =:= We1#we{perm=0}.
    
invalidate_by_mat(Changed0) ->
    Changed = ordsets:from_list(Changed0),
    wings_dl:map(fun(D, _) -> invalidate_by_mat(D, Changed) end, []).

invalidate_by_mat(#dlo{work=none,vs=none,smooth=none,proxy_faces=none}=D, _) ->
    %% Nothing to do.
    D;
invalidate_by_mat(#dlo{src_we=We}=D, Changed) ->
    Used = wings_facemat:used_materials(We),
    case ordsets:is_disjoint(Used, Changed) of
	true -> D;
	false -> D#dlo{work=none,edges=none,vs=none,smooth=none,proxy_faces=none}
    end.

invalidate_sel(#dlo{src_we=#we{id=Id},src_sel=SrcSel}=D,
	       [{Id,Items}|Sel], Mode) ->
    case SrcSel of
	{Mode,Items} -> {D,Sel};
	_ -> {D#dlo{sel=none,normals=none,src_sel={Mode,Items}},Sel}
    end;
invalidate_sel(D, Sel, _) ->
    {D#dlo{sel=none,src_sel=none},Sel}.

changed_we(#dlo{ns={_}=Ns}, D) ->
    D#dlo{ns=Ns};
changed_we(#dlo{ns=Ns}, D) ->
    D#dlo{ns={Ns}}.

update_normals(#dlo{ns={Ns0},src_we=#we{fs=Ftab}=We}=D) ->
    Ns = update_normals_1(Ns0, gb_trees:to_list(Ftab), We),
    D#dlo{ns=Ns};
update_normals(D) -> D.

update_normals_1(none, Ftab, We) ->
    update_normals_2(Ftab, [], We);
update_normals_1(Ns, Ftab, We) ->
    update_normals_2(Ftab, gb_trees:to_list(Ns), We).

update_normals_2(Ftab0, Ns, We) ->
    Ftab = wings_we:visible(Ftab0, We),
    update_normals_3(Ftab, Ns, We, []).

update_normals_3([{Face,Edge}|Fs], [{Face,Data}=Pair|Ns], We, Acc) ->
    Ps = wings_face:vertex_positions(Face, Edge, We),
    case Data of
	[_|Ps] ->
	    update_normals_3(Fs, Ns, We, [Pair|Acc]);
	{_,_,Ps} ->
	    update_normals_3(Fs, Ns, We, [Pair|Acc]);
	_ ->
	    update_normals_3(Fs, Ns, We, [{Face,face_ns_data(Ps)}|Acc])
    end;
update_normals_3([{Fa,_}|_]=Fs, [{Fb,_}|Ns], We, Acc) when Fa > Fb ->
    update_normals_3(Fs, Ns, We, Acc);
update_normals_3([{Face,Edge}|Fs], Ns, We, Acc) ->
    Ps = wings_face:vertex_positions(Face, Edge, We),
    update_normals_3(Fs, Ns, We, [{Face,face_ns_data(Ps)}|Acc]);
update_normals_3([], _, _, Acc) -> gb_trees:from_orddict(reverse(Acc)).

%% face_ns_data([Position]) ->
%%    [Normal|[Position]] |                        Tri or quad
%%    {Normal,[{VtxA,VtxB,VtxC}],[Position]}       Tesselated polygon
%%  Given the positions for a face, calculate the normal,
%%  and tesselate the face if necessary.
face_ns_data([_,_,_]=Ps) ->
    [e3d_vec:normal(Ps)|Ps];
face_ns_data([A,B,C,D]=Ps) ->
    N = e3d_vec:normal(Ps),
    case wings_draw_util:good_triangulation(N, A, B, C, D) of
	false -> {N,[{1,2,4},{4,2,3}],Ps};
	true -> [N|Ps]
    end;
face_ns_data(Ps0) ->
    N = e3d_vec:normal(Ps0),
    {Fs0,Ps} = wpc_ogla:triangulate(N, Ps0),
    Fs = face_ns_data_1(Fs0, []),
    {N,Fs,Ps}.

%% "Chain" vertices if possible so that the last vertex in
%% one triangle occurs as the first in the next triangle.
face_ns_data_1([{A,S,C}|Fs], [{_,_,S}|_]=Acc) ->
    face_ns_data_1(Fs, [{S,C,A}|Acc]);
face_ns_data_1([{A,B,S}|Fs], [{_,_,S}|_]=Acc) ->
    face_ns_data_1(Fs, [{S,A,B}|Acc]);
face_ns_data_1([F|Fs], Acc) ->
    face_ns_data_1(Fs, [F|Acc]);
face_ns_data_1([], Acc) -> Acc.

update_mirror(#dlo{mirror=none,src_we=#we{mirror=none}}=D) -> D;
update_mirror(#dlo{mirror=none,src_we=#we{fs=Ftab,mirror=Face}=We}=D) ->
    case gb_trees:is_defined(Face, Ftab) of
	false ->
	    D#dlo{mirror=none};
	true ->
	    VsPos = wings_face:vertex_positions(Face, We),
	    N = e3d_vec:normal(VsPos),
	    Center = e3d_vec:average(VsPos),
	    RotBack = e3d_mat:rotate_to_z(N),
	    Rot = e3d_mat:transpose(RotBack),
	    Mat0 = e3d_mat:mul(e3d_mat:translate(Center), Rot),
	    Mat1 = e3d_mat:mul(Mat0, e3d_mat:scale(1.0, 1.0, -1.0)),
	    Mat2 = e3d_mat:mul(Mat1, RotBack),
	    Mat = e3d_mat:mul(Mat2, e3d_mat:translate(e3d_vec:neg(Center))),
	    D#dlo{mirror=Mat}
    end;
update_mirror(D) -> D.

%% Find out which display lists are needed based on display modes.
%% (Does not check whether they exist or not; that will be checked
%% later.)

update_needed(#st{selmode=vertex}=St) ->
    case wings_pref:get_value(vertex_size) of
	0.0 ->
	    update_needed_1([], St);
	PointSize->
	    update_needed_1([{vertex,PointSize}], St)
    end;
update_needed(St) -> update_needed_1([], St).

update_needed_1(Need, St) ->
    case wings_pref:get_value(show_normals) of
	false -> update_needed_2(Need, St);
	true -> update_needed_2([normals|Need], St)
    end.

update_needed_2(CommonNeed, St) ->
    Wins = wins_of_same_class(),
    wings_dl:map(fun(D, _) ->
			 update_needed_fun(D, CommonNeed, Wins, St)
		 end, []).

update_needed_fun(#dlo{src_we=#we{perm=Perm}=We}=D, _, _, _)
  when ?IS_LIGHT(We), ?IS_VISIBLE(Perm) ->
    D#dlo{needed=[light]};
update_needed_fun(#dlo{src_we=#we{id=Id,he=Htab,pst=Pst},proxy_data=Pd}=D,
		   Need0, Wins, _) ->
    Need1 = case gb_sets:is_empty(Htab) orelse
		not wings_pref:get_value(show_edges) of
		false -> [hard_edges|Need0];
		true -> Need0
	    end,
	Need2 = wings_plugin:check_plugins(update_dlist,Pst) ++ Need1,
    Need = if
	       Pd =:= none -> Need2;
	       true -> [proxy|Need2]
	   end,
    D#dlo{needed=more_need(Wins, Id, Need)}.

more_need([W|Ws], Id, Acc0) ->
    Wire = wings_wm:get_prop(W, wireframed_objects),
    IsWireframe = gb_sets:is_member(Id, Wire),
    Acc = case {wings_wm:get_prop(W, workmode),IsWireframe} of
	      {false,true} ->
		  [edges,smooth|Acc0];
	      {false,false} ->
		  [smooth|Acc0];
	      {true,true} ->
		  [edges|Acc0];
	      {true,false} ->
		  case wings_pref:get_value(show_edges) of
		      false -> [work|Acc0];
		      true -> [edges,work|Acc0]
		  end
	  end,
    more_need(Ws, Id, Acc);
more_need([], _, Acc) ->
    ordsets:from_list(Acc).

wins_of_same_class() ->
    case wings_wm:get_prop(display_lists) of
	geom_display_lists -> wings_u:geom_windows();
	_ -> [wings_wm:this()]
    end.


%%
%% Rebuild all missing display lists, based on what is
%% actually needed in D#dlo.needed.
%%

build_dlists(St) ->
    wings_dl:map(fun(#dlo{needed=Needed}=D0, S0) ->
			 D = update_normals(D0),
			 S = update_materials(D, S0),
			 update_fun(D, Needed, S)
		 end, St).

update_fun(D0, [H|T], St) ->
    D = update_fun_2(H, D0, St),
    update_fun(D, T, St);
update_fun(D, [], _) -> D.

update_materials(D, St) ->
    We = original_we(D),
    if ?IS_ANY_LIGHT(We), ?HAS_SHAPE(We) ->
	    wings_light:shape_materials(We#we.light, St);
       true -> St
    end.

update_fun_2(light, D, _) ->
    wings_light:update(D);
update_fun_2(work, #dlo{work=none,src_we=#we{fs=Ftab}}=D, St) ->
    Dl = draw_faces(gb_trees:to_list(Ftab), D, St),
    D#dlo{work=Dl};
update_fun_2(smooth, #dlo{smooth=none,proxy_data=none}=D, St) ->
    {List,Tr} = smooth_dlist(D, St),
    D#dlo{smooth=List,transparent=Tr};
update_fun_2(smooth, #dlo{smooth=none}=D, St) ->
    We = wings_proxy:smooth_we(D),
    {List,Tr} = smooth_dlist(We, St),
    D#dlo{smooth=List,transparent=Tr};
update_fun_2({vertex,_PtSize}, #dlo{vs=none,src_we=We}=D, _) ->
    UnselDlist = gl:genLists(1),
    gl:newList(UnselDlist, ?GL_COMPILE),
    gl:enableClientState(?GL_VERTEX_ARRAY),
    drawVertices(?GL_POINTS, vertices_f32(visible_vertices(We))),
    gl:disableClientState(?GL_VERTEX_ARRAY),
    gl:endList(),
    D#dlo{vs=UnselDlist};
update_fun_2(hard_edges, #dlo{hard=none,src_we=#we{he=Htab}=We}=D, _) ->
    List = gl:genLists(1),
    gl:newList(List, ?GL_COMPILE),
    gl:enableClientState(?GL_VERTEX_ARRAY),
    drawVertices(?GL_LINES, edges_f32(gb_sets:to_list(Htab), We)),
    gl:disableClientState(?GL_VERTEX_ARRAY),
    gl:endList(),
    D#dlo{hard=List};
update_fun_2(edges, #dlo{edges=none,ns=Ns}=D, _) ->
    EdgeDl = make_edge_dl(gb_trees:values(Ns)),
    D#dlo{edges=EdgeDl};
update_fun_2(normals, D, _) ->
    make_normals_dlist(D);
update_fun_2(proxy, D, St) ->
    wings_proxy:update(D, St);

%%%% Check if plugins using the Pst need a draw list updated.
update_fun_2({plugin,{Plugin,{_,_}=Data}},#dlo{plugins=Pdl}=D,St) ->
    case lists:keytake(Plugin,1,Pdl) of
	    false ->
		  Plugin:update_dlist(Data,D,St);
	    {_,{Plugin,{_,none}},Pdl0} ->
	      Plugin:update_dlist(Data,D#dlo{plugins=Pdl0},St);
		_ -> D
	end;

update_fun_2(_, D, _) -> D.

make_edge_dl(Ns) ->
    Dl = gl:genLists(1),
    gl:newList(Dl, ?GL_COMPILE),
    {Tris,Quads,Polys,PsLens} = make_edge_dl_bin(Ns, <<>>, <<>>, <<>>, []),
    gl:enableClientState(?GL_VERTEX_ARRAY),
    drawVertices(?GL_TRIANGLES, Tris),    
    drawVertices(?GL_QUADS, Quads),
    drawPolygons(Polys, PsLens),
    gl:disableClientState(?GL_VERTEX_ARRAY),
    gl:endList(),
    Dl.

make_edge_dl_bin([[_|[{X1,Y1,Z1},{X2,Y2,Z2},{X3,Y3,Z3}]]|Ns],
		 Tris0, Quads, Polys, PsLens) ->
    Tris = <<Tris0/binary,X1:?F32,Y1:?F32,Z1:?F32,X2:?F32,Y2:?F32,Z2:?F32,
	    X3:?F32,Y3:?F32,Z3:?F32>>,
    make_edge_dl_bin(Ns, Tris, Quads, Polys, PsLens);
make_edge_dl_bin([[_|[{X1,Y1,Z1},{X2,Y2,Z2},{X3,Y3,Z3},{X4,Y4,Z4}]]|Ns],
		 Tris, Quads0, Polys, PsLens) ->
    Quads = <<Quads0/binary,X1:?F32,Y1:?F32,Z1:?F32,X2:?F32,Y2:?F32,Z2:?F32,
	     X3:?F32,Y3:?F32,Z3:?F32,X4:?F32,Y4:?F32,Z4:?F32>>,
    make_edge_dl_bin(Ns, Tris, Quads, Polys, PsLens);
make_edge_dl_bin([{_,_,VsPos}|Ns], Tris, Quads, Polys, PsLens) ->
    Poly = vertices_f32(VsPos),
    NoVs = byte_size(Poly) div 12,
    make_edge_dl_bin(Ns,Tris,Quads,<<Polys/binary,Poly/binary>>,[NoVs|PsLens]);
make_edge_dl_bin([], Tris, Quads, Polys, PsLens) ->
    {Tris, Quads, Polys, reverse(PsLens)}.

edges_f32(Edges, #we{es=Etab,vp=Vtab}) ->
    edges_f32(Edges,Etab,Vtab,<<>>).
edges_f32([Edge|Edges],Etab,Vtab,Bin0) ->
    #edge{vs=Va,ve=Vb} = array:get(Edge, Etab),
    {X1,Y1,Z1} = array:get(Va, Vtab),
    {X2,Y2,Z2} = array:get(Vb, Vtab),
    Bin = <<Bin0/binary,X1:?F32,Y1:?F32,Z1:?F32,X2:?F32,Y2:?F32,Z2:?F32>>,
    edges_f32(Edges, Etab, Vtab, Bin);
edges_f32([],_,_,Bin) ->
    Bin.

vertices_f32([{_,{_,_,_}}|_]=List) ->
    << <<X:?F32,Y:?F32,Z:?F32>> || {_,{X,Y,Z}} <- List >>;
vertices_f32([{_,_,_}|_]=List) ->
    << <<X:?F32,Y:?F32,Z:?F32>> || {X,Y,Z} <- List >>;
vertices_f32([]) -> <<>>.

drawVertices(_Type, <<>>) -> 
    ok;
drawVertices(Type, Bin) -> 
    gl:vertexPointer(3, ?GL_FLOAT, 0, Bin), 
    gl:drawArrays(Type, 0, byte_size(Bin) div 12).

drawPolygons(<<>>, _PsLens) -> 
    ok;
drawPolygons(Polys, PsLens) ->
    gl:vertexPointer(3, ?GL_FLOAT, 0, Polys), 
    foldl(fun(Length,Start) ->
		  gl:drawArrays(?GL_POLYGON, Start, Length),
		  Length+Start
	  end, 0, PsLens).

force_flat([], _) -> [];
force_flat([H|T], Color) ->
    [force_flat(H, Color)|force_flat(T, Color)];
force_flat({call,_,Faces}, Color) ->
    wings_draw_util:force_flat_color(Faces, Color);
force_flat(_, _) -> none.

visible_vertices(#we{vp=Vtab0}=We) ->
    case wings_we:any_hidden(We) of
	false ->
	    array:sparse_to_list(Vtab0);
	true ->
	    Vis0 = wings_we:visible_vs(We),
	    Vis = sofs:from_external(Vis0, [vertex]),
	    Vtab = sofs:from_external(array:sparse_to_list(Vtab0),
				      [{vertex,position}]),
	    sofs:to_external(sofs:image(Vtab, Vis))
    end.


%%%
%%% Update the selection display list.
%%%

update_sel_dlist() ->
    wings_dl:map(fun(D, _) ->
			 update_sel(D)
		 end, []).

update_sel(#dlo{src_we=We}=D) when ?IS_LIGHT(We) -> {D,[]};
update_sel(#dlo{sel=none,src_sel={body,_}}=D) ->
    update_sel_all(D);
update_sel(#dlo{split=none,sel=none,src_sel={face,Faces},
		src_we=#we{fs=Ftab}}=D) ->
    %% If we are not dragging (no dlists splitted), we can
    %% optimize the showing of the selection.
    case gb_trees:size(Ftab) =:= gb_sets:size(Faces) of
	true -> update_sel_all(D);
	false -> update_face_sel(gb_sets:to_list(Faces), D)
    end;
update_sel(#dlo{sel=none,src_sel={face,Faces}}=D) ->
    %% We are dragging. Don't try to be tricky here.
    update_face_sel(gb_sets:to_list(Faces), D);
update_sel(#dlo{sel=none,src_sel={edge,Edges}}=D) ->
    #dlo{src_we=We} = D,
    List = gl:genLists(1),
    gl:newList(List, ?GL_COMPILE),
    gl:enableClientState(?GL_VERTEX_ARRAY),
    drawVertices(?GL_LINES, edges_f32(gb_sets:to_list(Edges), We)),
    gl:disableClientState(?GL_VERTEX_ARRAY),
    gl:endList(),
    D#dlo{sel=List};
update_sel(#dlo{sel=none,src_sel={vertex,Vs}}=D) ->
    #dlo{src_we=#we{vp=Vtab0}} = D,
    SelDlist = gl:genLists(1),
    Vtab1 = array:sparse_to_orddict(Vtab0),
    case length(Vtab1) =:= gb_sets:size(Vs) of
	true ->
	    gl:newList(SelDlist, ?GL_COMPILE),
	    gl:enableClientState(?GL_VERTEX_ARRAY),
	    drawVertices(?GL_POINTS, vertices_f32(Vtab1)),
	    gl:disableClientState(?GL_VERTEX_ARRAY),
	    gl:endList(),
	    D#dlo{sel=SelDlist};
	false ->
	    Vtab = sofs:from_external(Vtab1, [{vertex,data}]),
	    R = sofs:from_external(gb_sets:to_list(Vs), [vertex]),
	    Sel = sofs:to_external(sofs:image(Vtab, R)),

	    gl:newList(SelDlist, ?GL_COMPILE),
	    gl:enableClientState(?GL_VERTEX_ARRAY),
	    drawVertices(?GL_POINTS, vertices_f32(Sel)),
	    gl:disableClientState(?GL_VERTEX_ARRAY),
	    gl:endList(),

	    D#dlo{sel=SelDlist}
    end;
update_sel(#dlo{}=D) -> D.

%% Select all faces.
update_sel_all(#dlo{src_we=#we{mode=vertex},work=Work}=D) ->
    Dl = force_flat(Work, wings_pref:get_value(selected_color)),
    D#dlo{sel=Dl};
update_sel_all(#dlo{work=Faces}=D) when Faces =/= none ->
    D#dlo{sel=Faces};
update_sel_all(#dlo{smooth=Faces}=D) when Faces =/= none ->
    D#dlo{sel=Faces};
update_sel_all(#dlo{src_we=#we{fs=Ftab}}=D) ->
    %% No suitable display list to re-use. Build selection from scratch.
    update_face_sel(gb_trees:keys(Ftab), D).

update_face_sel(Fs0, #dlo{src_we=We}=D) ->
    Fs = wings_we:visible(Fs0, We),
    List = gl:genLists(1),
    gl:newList(List, ?GL_COMPILE),     
    BinFs = update_face_sel_1(Fs, D, <<>>),
    gl:enableClientState(?GL_VERTEX_ARRAY),
    drawVertices(?GL_TRIANGLES, BinFs),
    gl:disableClientState(?GL_VERTEX_ARRAY),
    gl:endList(),
    D#dlo{sel=List}.

update_face_sel_1(Fs, #dlo{ns=none,src_we=We}, Bin) ->
    update_face_sel_2(Fs, We, Bin);
update_face_sel_1(Fs, #dlo{ns={_},src_we=We}, Bin) ->
    update_face_sel_2(Fs, We, Bin);
update_face_sel_1(Fs, D, Bin) ->
    update_face_sel_2(Fs, D, Bin).

update_face_sel_2([F|Fs], D, Bin0) ->
    Bin = wings_draw_util:unlit_face_bin(F, D, Bin0),
    update_face_sel_2(Fs, D, Bin);
update_face_sel_2([], _, Bin) -> Bin.

%%%
%%% Splitting of objects into two display lists.
%%%

split(#dlo{ns={Ns0},src_we=#we{fs=Ftab}}=D, Vs, St) ->
    Ns = remove_stale_ns(Ns0, Ftab),
    split_1(D#dlo{ns=Ns}, Vs, St);
split(D, Vs, St) -> split_1(D, Vs, St).

split_1(#dlo{split=#split{orig_we=#we{}=We,orig_ns=Ns}}=D, Vs, St) ->
    split_2(D#dlo{src_we=We,ns=Ns}, Vs, update_materials(D, St));
split_1(D, Vs, St) ->
    split_2(D, Vs, update_materials(D, St)).

split_2(#dlo{mirror=M,src_sel=Sel,src_we=#we{fs=Ftab}=We,
	     proxy_data=Pd,ns=Ns0,needed=Needed,open=Open}=D, Vs0, St) ->
    Vs = sort(Vs0),
    Faces = wings_we:visible(wings_face:from_vs(Vs, We), We),
    StaticVs = static_vs(Faces, Vs, We),

    VisFtab = wings_we:visible(gb_trees:to_list(Ftab), We),
    {Work,FtabDyn} = split_faces(D, VisFtab, Faces, St),
    StaticEdgeDl = make_static_edges(Faces, D),
    {DynVs,VsDlist} = split_vs_dlist(Vs, StaticVs, Sel, We),

    WeDyn = wings_facemat:gc(We#we{fs=gb_trees:from_orddict(FtabDyn)}),
    DynPlan = wings_draw_util:prepare(FtabDyn, We, St),
    StaticVtab = insert_vtx_data(StaticVs, We#we.vp, []),

    Split = #split{static_vs=StaticVtab,dyn_vs=DynVs,
		   dyn_plan=DynPlan,orig_ns=Ns0,orig_we=We},
    #dlo{work=Work,edges=[StaticEdgeDl],mirror=M,vs=VsDlist,
	 src_sel=Sel,src_we=WeDyn,split=Split,proxy_data=Pd,
	 needed=Needed,open=Open}.

remove_stale_ns(none, _) -> none;
remove_stale_ns(Ns, Ftab) ->
    remove_stale_ns_1(gb_trees:to_list(Ns), Ftab, []).

remove_stale_ns_1([{F,_}=Pair|Fs], Ftab, Acc) ->
    case gb_trees:is_defined(F, Ftab) of
	false -> remove_stale_ns_1(Fs, Ftab, Acc);
	true -> remove_stale_ns_1(Fs, Ftab, [Pair|Acc])
    end;
remove_stale_ns_1([], _, Acc) ->
    gb_trees:from_orddict(reverse(Acc)).

static_vs(Fs, Vs, We) ->
    VsSet = gb_sets:from_ordset(Vs),
    Fun = fun(V, _, _, A) ->
		  case gb_sets:is_member(V, VsSet) of
 		      false -> [V|A];
 		      true -> A
 		  end
 	  end,
    static_vs_1(Fs, Fun, We, []).

static_vs_1([F|Fs], Fun, We, Acc) ->
    static_vs_1(Fs, Fun, We, wings_face:fold(Fun, Acc, F, We));
static_vs_1([], _, _, Acc) -> ordsets:from_list(Acc).

split_faces(#dlo{needed=Need}=D, Ftab0, Fs0, St) ->
    Ftab = sofs:from_external(Ftab0, [{face,data}]),
    Fs = sofs:from_external(Fs0, [face]),
    case member(work, Need) orelse member(smooth, Need) of
	false ->
	    %% This is wireframe mode. We don't need any
	    %% 'work' display list for faces.
	    FtabDyn = sofs:to_external(sofs:restriction(Ftab, Fs)),
	    {none,FtabDyn};
	true ->
	    %% Faces needed. (Either workmode or smooth mode.)
	    {FtabDyn0,StaticFtab0} = sofs:partition(1, Ftab, Fs),
	    FtabDyn = sofs:to_external(FtabDyn0),
	    StaticFtab = sofs:to_external(StaticFtab0),
	    {[draw_faces(StaticFtab, D, St)],FtabDyn}
    end.

make_static_edges(DynFaces, #dlo{ns=none}) ->
    make_static_edges_1(DynFaces, [], []);
make_static_edges(DynFaces, #dlo{ns=Ns}) ->
    make_static_edges_1(DynFaces, gb_trees:to_list(Ns), []).

make_static_edges_1([F|Fs], [{F,_}|Ns], Acc) ->
    make_static_edges_1(Fs, Ns, Acc);
make_static_edges_1([_|_]=Fs, [{_,N}|Ns], Acc) ->
    make_static_edges_1(Fs, Ns, [N|Acc]);
make_static_edges_1(_, Ns, Acc) ->
    make_static_edges_2(Ns, Acc).

make_static_edges_2([{_,N}|Ns], Acc) ->
    make_static_edges_2(Ns, [N|Acc]);
make_static_edges_2([], Acc) ->
    make_edge_dl(Acc).

insert_vtx_data([V|Vs], Vtab, Acc) ->
    insert_vtx_data(Vs, Vtab, [{V,array:get(V, Vtab)}|Acc]);
insert_vtx_data([], _, Acc) -> reverse(Acc).

split_vs_dlist(Vs, StaticVs, {vertex,SelVs0}, #we{vp=Vtab}=We) ->
    case wings_pref:get_value(vertex_size) of
	0.0 -> {none,none};
	_PtSize -> 
	    DynVs = sofs:from_external(lists:merge(Vs, StaticVs), [vertex]),
	    SelVs = sofs:from_external(gb_sets:to_list(SelVs0), [vertex]),
	    UnselDyn0 = case wings_pref:get_value(hide_sel_while_dragging) of
			    false -> sofs:difference(DynVs, SelVs);
			    true -> DynVs
			end,
	    UnselDyn = sofs:to_external(UnselDyn0),
	    UnselDlist = gl:genLists(1),
	    gl:newList(UnselDlist, ?GL_COMPILE),
	    List0 = sofs:from_external(array:sparse_to_orddict(Vtab),
				       [{vertex,info}]),
	    List1 = sofs:drestriction(List0, DynVs),
	    List2 = sofs:to_external(List1),
	    List = wings_we:visible_vs(List2, We),
	    VisibleVs = << <<X:?F32,Y:?F32,Z:?F32>> || {_,{X,Y,Z}} <- List >>,
	    gl:enableClientState(?GL_VERTEX_ARRAY),
	    drawVertices(?GL_POINTS, VisibleVs),
	    gl:disableClientState(?GL_VERTEX_ARRAY),
	    gl:endList(),
	    {UnselDyn,[UnselDlist]}
    end;
split_vs_dlist(_, _, _, _) -> {none,none}.
    
original_we(#dlo{split=#split{orig_we=We}}) -> We;
original_we(#dlo{src_we=We}) -> We.

%%%
%%% Updating of the dynamic part of a split dlist.
%%%

update_dynamic(#dlo{src_we=We}=D, Vtab) when ?IS_LIGHT(We) ->
    wings_light:update_dynamic(D, Vtab);
update_dynamic(#dlo{src_we=We0,split=#split{static_vs=StaticVs}}=D0, Vtab0) ->
    Vtab1 = keysort(1, StaticVs++Vtab0),
    Vtab = array:from_orddict(Vtab1),
    We = We0#we{vp=Vtab},
    D1 = D0#dlo{src_we=We},
    D2 = changed_we(D0, D1),
    D3 = update_normals(D2),
    D4 = dynamic_faces(D3),
    D = dynamic_edges(D4),
    dynamic_vs(D).

dynamic_faces(#dlo{work=[Work|_],split=#split{dyn_plan=DynPlan}}=D) ->
    Dl = draw_faces(DynPlan, D),
    D#dlo{work=[Work,Dl]};
dynamic_faces(#dlo{work=none}=D) -> D.

dynamic_edges(#dlo{edges=[StaticEdge|_],ns=Ns}=D) ->
    EdgeDl = make_edge_dl(gb_trees:values(Ns)),
    D#dlo{edges=[StaticEdge,EdgeDl]}.

dynamic_vs(#dlo{split=#split{dyn_vs=none}}=D) -> D;
dynamic_vs(#dlo{src_we=#we{vp=Vtab},vs=[Static|_],
		split=#split{dyn_vs=DynVs}}=D) ->
    UnselDlist = gl:genLists(1),
    gl:newList(UnselDlist, ?GL_COMPILE),
    DynVsBin = foldl(fun(V, Bin) ->
			     {X1,Y1,Z1} = array:get(V, Vtab),
			     <<Bin/binary, X1:?F32,Y1:?F32,Z1:?F32>>
		      end, <<>>, DynVs),
    gl:enableClientState(?GL_VERTEX_ARRAY),
    drawVertices(?GL_POINTS, DynVsBin),
    gl:disableClientState(?GL_VERTEX_ARRAY),
    gl:endList(),
    D#dlo{vs=[Static,UnselDlist]}.

%%%
%%% Abort a split.
%%%

abort_split(#dlo{split=#split{orig_ns=Ns}}=D) ->
    %% Restoring the original normals will probably be beneficial.
    D#dlo{split=none,ns=Ns};
abort_split(D) -> D.

%%%
%%% Re-joining of display lists that have been split.
%%%

join(#dlo{src_we=#we{vp=Vtab0},ns=Ns1,split=#split{orig_we=We0,orig_ns=Ns0}}=D) ->
    #we{vp=OldVtab} = We0,

    Vtab = join_update(Vtab0, OldVtab),
    We = We0#we{vp=Vtab},
    Ns = join_ns(We, Ns1, Ns0),
    D#dlo{vs=none,drag=none,sel=none,split=none,src_we=We,ns=Ns}.

join_ns(We, _, _) when ?IS_LIGHT(We) ->
    none;
join_ns(_, NsNew, none) ->
    NsNew;
join_ns(#we{fs=Ftab}, NsNew, NsOld) ->
    join_ns_1(gb_trees:to_list(NsNew), gb_trees:to_list(NsOld), Ftab, []).

join_ns_1([{Face,_}=El|FsNew], [{Face,_}|FsOld], Ftab, Acc) ->
    %% Same face: Use new contents.
    join_ns_1(FsNew, FsOld, Ftab, [El|Acc]);
join_ns_1([{Fa,_}|_]=FsNew, [{Fb,_}=El|FsOld], Ftab, Acc) when Fa > Fb ->
    %% Face only in old list: Check in Ftab if it should be kept.
    case gb_trees:is_defined(Fb, Ftab) of
	false -> join_ns_1(FsNew, FsOld, Ftab, Acc);
	true -> join_ns_1(FsNew, FsOld, Ftab, [El|Acc])
    end;
join_ns_1([El|FsNew], FsOld, Ftab, Acc) ->
    %% Fa < Fb: New face.
    join_ns_1(FsNew, FsOld, Ftab, [El|Acc]);
join_ns_1([], Fs, _, Acc) ->
    gb_trees:from_orddict(reverse(Acc, Fs)).

join_update(New, Old) ->
    join_update(array:sparse_to_orddict(New), array:sparse_to_orddict(Old), Old).

join_update([Same|New], [Same|Old], Acc) ->
    join_update(New, Old, Acc);
join_update([{V,P0}|New], [{V,OldP}|Old], Acc) ->
    P = tricky_share(P0, OldP),
    join_update(New, Old, array:set(V, P, Acc));
join_update(New, [_|Old], Acc) ->
    join_update(New, Old, Acc);
join_update([], _, Acc) -> Acc.

%% Too obvious to comment. :-)
tricky_share({X,Y,Z}=New, {OldX,OldY,OldZ})
  when X =/= OldX, Y =/= OldY, Z =/= OldZ -> New;
tricky_share({X,Y,Z}, {X,Y,_}=Old) ->
    setelement(3, Old, Z);
tricky_share({X,Y,Z}, {X,_,Z}=Old) ->
    setelement(2, Old, Y);
tricky_share({X,Y,Z}, {_,Y,Z}=Old) ->
    setelement(1, Old, X);
tricky_share({X,Y,Z}, {X,_,_}=Old) ->
    {element(1, Old),Y,Z};
tricky_share({X,Y,Z}, {_,Y,_}=Old) ->
    {X,element(2, Old),Z};
tricky_share({X,Y,Z}, {_,_,Z}=Old) ->
    {X,Y,element(3, Old)}.

%%%
%%% Drawing routines for workmode.
%%%

draw_faces(Ftab, D, St) ->
    draw_faces(wings_draw_util:prepare(Ftab, D, St), D).

draw_faces({material,MatFaces,St}, D) ->
    Dl = gl:genLists(1),
    gl:newList(Dl, ?GL_COMPILE),
    mat_faces(MatFaces, D, St),
    gl:endList(),
    Dl;
draw_faces({color,Colors,#st{mat=Mtab}}, D) ->
    BasicFaces = gl:genLists(2),
    Dl = BasicFaces+1,
    gl:newList(BasicFaces, ?GL_COMPILE),
    draw_vtx_faces(Colors, D),
    gl:endList(),
    
    gl:newList(Dl, ?GL_COMPILE),
    wings_material:apply_material(default, Mtab),
    gl:enable(?GL_COLOR_MATERIAL),
    gl:colorMaterial(?GL_FRONT_AND_BACK, ?GL_AMBIENT_AND_DIFFUSE),
    gl:callList(BasicFaces),
    gl:disable(?GL_COLOR_MATERIAL),
    gl:endList(),

    {call,Dl,BasicFaces}.

draw_vtx_faces({Same,Diff}, D) ->
    gl:'begin'(?GL_TRIANGLES),
    draw_vtx_faces_1(Same, D),
    draw_vtx_faces_3(Diff, D),
    gl:'end'().

draw_vtx_faces_1([{none,Faces}|Fs], D) ->
    gl:color3f(1, 1, 1),
    draw_vtx_faces_2(Faces, D),
    draw_vtx_faces_1(Fs, D);
draw_vtx_faces_1([{Col,Faces}|Fs], D) ->
    gl:color3fv(Col),
    draw_vtx_faces_2(Faces, D),
    draw_vtx_faces_1(Fs, D);
draw_vtx_faces_1([], _) -> ok.

draw_vtx_faces_2([F|Fs], D) ->
    wings_draw_util:plain_face(F, D),
    draw_vtx_faces_2(Fs, D);
draw_vtx_faces_2([], _) -> ok.

draw_vtx_faces_3([[F|Cols]|Fs], D) ->
    wings_draw_util:vcol_face(F, D, Cols),
    draw_vtx_faces_3(Fs, D);
draw_vtx_faces_3([], _) -> ok.

%%%
%%% Set material and draw faces.
%%%

mat_faces(List, #dlo{}=D, #st{mat=Mtab}) ->
    mat_faces_1(List, D, Mtab);
mat_faces(List, D, Mtab) ->
    mat_faces_1(List, D, Mtab).
    
mat_faces_1([{Mat,Faces}|T], D, Mtab) ->
    gl:pushAttrib(?GL_TEXTURE_BIT),
    case wings_material:apply_material(Mat, Mtab) of
	false ->
	    gl:'begin'(?GL_TRIANGLES),
	    draw_mat_faces(Faces, D),
	    gl:'end'();
	true ->
	    gl:'begin'(?GL_TRIANGLES),
	    draw_uv_faces(Faces, D),
	    gl:'end'()
    end,
    gl:popAttrib(),
    mat_faces_1(T, D, Mtab);
mat_faces_1([], _, _) -> ok.

draw_mat_faces([{Face,_Edge}|Fs], D) ->
    wings_draw_util:plain_face(Face, D),
    draw_mat_faces(Fs, D);
draw_mat_faces([], _) -> ok.

draw_uv_faces([{Face,Edge}|Fs], D) ->
    wings_draw_util:uv_face(Face, Edge, D),
    draw_uv_faces(Fs, D);
draw_uv_faces([], _) -> ok.

%%%
%%% Smooth drawing.
%%%

smooth_dlist(#dlo{src_we=#we{}=We,ns=Ns0}=D, St) ->
    Ns1 = foldl(fun({F,[N|_]}, A) -> [{F,N}|A];
		   ({F,{N,_,_}}, A) -> [{F,N}|A]
		end, [], gb_trees:to_list(Ns0)),
    Ns = reverse(Ns1),
    Flist = wings_we:normals(Ns, We),
    smooth_faces(Flist, D, St);
smooth_dlist(We, St) ->
    D = update_normals(changed_we(#dlo{}, #dlo{src_we=We})),
    smooth_dlist(D, St).

smooth_faces(Ftab, D, St) ->
    smooth_faces(wings_draw_util:prepare(Ftab, D, St), D).

smooth_faces({material,MatFaces,St}, #dlo{ns=Ns}) ->
    Draw = fun(false, Fs) ->
		   wings_draw_util:smooth_plain_faces(Fs, Ns);
	      (true, Fs) ->
		   wings_draw_util:smooth_uv_faces(Fs, Ns)
	   end,
    draw_smooth_faces(Draw, MatFaces, St);
smooth_faces({color,{Same,Diff},#st{mat=Mtab}}, #dlo{ns=Ns}) ->
    ListOp = gl:genLists(1),
    gl:newList(ListOp, ?GL_COMPILE),
    wings_material:apply_material(default, Mtab),
    gl:enable(?GL_COLOR_MATERIAL),
    gl:colorMaterial(?GL_FRONT_AND_BACK, ?GL_AMBIENT_AND_DIFFUSE),
    gl:'begin'(?GL_TRIANGLES),
    draw_smooth_vtx_faces_1(Same, Ns),
    wings_draw_util:smooth_vcol_faces(Diff, Ns),
    gl:'end'(),
    gl:disable(?GL_COLOR_MATERIAL),
    gl:endList(),
    {[ListOp,none],false}.

draw_smooth_vtx_faces_1([{none,Faces}|MatFaces], Ns) ->
    gl:color3f(1.0, 1.0, 1.0),
    wings_draw_util:smooth_plain_faces(Faces, Ns),
    draw_smooth_vtx_faces_1(MatFaces, Ns);
draw_smooth_vtx_faces_1([{Col,Faces}|MatFaces], Ns) ->
    gl:color3fv(Col),
    wings_draw_util:smooth_plain_faces(Faces, Ns),
    draw_smooth_vtx_faces_1(MatFaces, Ns);
draw_smooth_vtx_faces_1([], _) -> ok.

draw_smooth_faces(DrawFace, Flist, #st{mat=Mtab}) ->
    ListOp = gl:genLists(1),
    gl:newList(ListOp, ?GL_COMPILE),
    Trans = draw_smooth_opaque(Flist, DrawFace, Mtab, []),
    gl:endList(),
    if
	Trans =:= [] ->
	    {[ListOp,none],false};
	true ->
	    ListTr = gl:genLists(1),
	    gl:newList(ListTr, ?GL_COMPILE),
	    draw_smooth_tr(Flist, DrawFace, Mtab),
	    gl:endList(),
	    {[ListOp,ListTr],true}
    end.

draw_smooth_opaque([{M,Faces}=MatFaces|T], DrawFace, Mtab, Acc) ->
    case wings_material:is_transparent(M, Mtab) of
	true ->
	    draw_smooth_opaque(T, DrawFace, Mtab, [MatFaces|Acc]);
	false ->
	    do_draw_smooth(DrawFace, M, Faces, Mtab),
	    draw_smooth_opaque(T, DrawFace, Mtab, Acc)
    end;
draw_smooth_opaque([], _, _, Acc) -> Acc.

draw_smooth_tr([{M,Faces}|T], DrawFace, Mtab) ->
    do_draw_smooth(DrawFace, M, Faces, Mtab),
    draw_smooth_tr(T, DrawFace, Mtab);
draw_smooth_tr([], _, _) -> ok.

do_draw_smooth(DrawFaces, Mat, Faces, Mtab) ->
    gl:pushAttrib(?GL_TEXTURE_BIT),
    IsTxMaterial = wings_material:apply_material(Mat, Mtab),
    gl:'begin'(?GL_TRIANGLES),
    DrawFaces(IsTxMaterial, Faces),
    gl:'end'(),
    gl:popAttrib().

%%
%% Draw normals for the selected elements.
%%

make_normals_dlist(#dlo{normals=none,src_we=We,src_sel={Mode,Elems}}=D) ->
    List = gl:genLists(1),
    gl:newList(List, ?GL_COMPILE),
    gl:color3fv(wings_pref:get_value(normal_vector_color)),
    Normals = make_normals_dlist_1(Mode, Elems, We),
    gl:enableClientState(?GL_VERTEX_ARRAY),
    drawVertices(?GL_LINES, Normals),
    gl:disableClientState(?GL_VERTEX_ARRAY),
    gl:endList(),
    D#dlo{normals=List};
make_normals_dlist(#dlo{src_sel=none}=D) -> D#dlo{normals=none};
make_normals_dlist(D) -> D.

make_normals_dlist_1(vertex, Vs, #we{vp=Vtab}=We) ->
    Length = wings_pref:get_value(normal_vector_size),
    foldl(fun(V, Bin) ->
		  {X1,Y1,Z1} = Pos = array:get(V, Vtab),
		  N = wings_vertex:normal(V, We),
		  {X2,Y2,Z2} = e3d_vec:add_prod(Pos, N, Length),
		  <<Bin/binary, X1:?F32,Y1:?F32,Z1:?F32,X2:?F32,Y2:?F32,Z2:?F32>>
	  end, <<>>, gb_sets:to_list(Vs));
make_normals_dlist_1(edge, Edges, #we{es=Etab,vp=Vtab}=We) ->
    Et0 = sofs:relation(array:sparse_to_orddict(Etab), [{edge,data}]),
    Es = sofs:from_external(gb_sets:to_list(Edges), [edge]),
    Et1 = sofs:restriction(Et0, Es),
    Et = sofs:to_external(Et1),
    Length = wings_pref:get_value(normal_vector_size),
    foldl(fun({_,#edge{vs=Va,ve=Vb,lf=Lf,rf=Rf}}, Bin) ->
		  PosA = array:get(Va, Vtab),
		  PosB = array:get(Vb, Vtab),
		  {X1,Y1,Z1} = Mid = e3d_vec:average(PosA, PosB),
		  N = e3d_vec:average(wings_face:normal(Lf, We),
				      wings_face:normal(Rf, We)),
		  {X2,Y2,Z2} = e3d_vec:add_prod(Mid, N, Length),
		  <<Bin/binary, X1:?F32,Y1:?F32,Z1:?F32,X2:?F32,Y2:?F32,Z2:?F32>> 
	  end, <<>>, Et);
make_normals_dlist_1(face, Faces, We) ->
    Length = wings_pref:get_value(normal_vector_size),
    foldl(fun(Face, Bin) ->
		  Vs = wings_face:vertices_cw(Face, We),
		  {X1,Y1,Z1} = C = wings_vertex:center(Vs, We),
		  N = wings_face:face_normal_cw(Vs, We),
		  {X2,Y2,Z2} = e3d_vec:add_prod(C, N, Length),
		  <<Bin/binary, X1:?F32,Y1:?F32,Z1:?F32,X2:?F32,Y2:?F32,Z2:?F32>> 
	    end, <<>>, wings_we:visible(gb_sets:to_list(Faces), We));
make_normals_dlist_1(body, _, #we{fs=Ftab}=We) ->
    make_normals_dlist_1(face, gb_sets:from_list(gb_trees:keys(Ftab)), We).
