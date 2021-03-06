(*
 * Copyright (C) 2006-2012 Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)

(* Xenserver VM operations *)

open Lwt

module X = Xen_api_lwt_unix

open Cohttp_lwt_unix
open Host

open CamlTemplate.Model

type installty = 
| Pxe of string (* branch name *)
| Mainiso of string (* iso name *)
| Custom (* once a VXS template has been changed *)
	    
with rpc

let string_of_installty x = Jsonrpc.to_string (rpc_of_installty x) 

let pxedir = "/usr/groups/netboot/pxelinux.cfg"

(* API:
 *
 * Vxs.template_create : host_config -> branch:string -> uuid:string
 * Vxs.template_list : host_config -> uuid:string * (name * branch * build_number) list
 * Vxs.create_pool : 
 * 
 *)

type vxs_template_config = {
	  ty : installty;              (* e.g. Pxe "trunk-ring3" or Mainiso "main.iso" *)
    
	  vm_uuid : string;                  (* VM uuid *)
	  vxs_root_password : string; 
    
	  post_install : Blob.t;   (* Called by the host installer *)
	  initscript : Blob.t;     (* Called on firstboot before firstboot
							                  scripts! (sets host/dom0 uuid) *)
	  veryfirstboot : Blob.t;  (* Installed into firstboot.d *)
	  firstboot : Blob.t; 
	  id_dsa : Blob.t;
	  answerfile : Blob.t;     (* Host installer answerfile *)
	  vsed : Blob.t;
}

type vxs_pool_config = {
	  n : int;
	  name : string;
	  networks : int;
}

let submit_rpc host_config session_id uuid cmd =
  let rpc = Host.get_rpc host_config in
  lwt vm = X.VM.get_by_uuid rpc session_id uuid in
  lwt other_config = X.VM.get_other_config rpc session_id vm in
  let get stem =
    let rpcs = List.filter (fun (k,v) -> Utils.startswith stem k) other_config in
    let len = String.length stem in
    let rpcs = List.map (fun (k,v) -> try [(int_of_string (String.sub k len (String.length k - len)),v)] with _ -> []) rpcs in
    let rpcs = List.concat rpcs in
    rpcs
  in
  let rpcs = get "rpc" in
  let max = List.fold_left (fun x (y,_) -> max x y) 0 rpcs in
  let new_rpc = max + 1 in
  let rpcname = Printf.sprintf "rpc%d" new_rpc in
  lwt blob = Blob.add_blob rpc session_id vm rpcname in
  lwt () = Blob.put_blob host_config session_id blob cmd in
  lwt () = X.VM.add_to_other_config rpc session_id vm rpcname blob.Blob.u in
  return new_rpc
    
let get_response host_config session_id uuid n =
  let rpc = Host.get_rpc host_config in
  lwt vm_ref = X.VM.get_by_uuid rpc session_id uuid in
  let response = Printf.sprintf "response%d" n in
  let rec process_events token = 
    lwt events = X.Event.from ~rpc ~session_id ~classes:[Printf.sprintf "vm/%s" vm_ref] ~token ~timeout:60.0 in
    
    let ef = Event_types.event_from_of_rpc events in 
    lwt results = Lwt_list.map_s (fun ev -> 
      Lwt.return (match Event_helper.record_of_event ev with
      | Event_helper.VM (_ref,Some record) -> 
	if List.mem_assoc response record.API.vM_other_config 
	then Some (List.assoc response record.API.vM_other_config)
	else None
      | _ ->
	None)) ef.Event_types.events in
    let result = List.fold_left (fun acc x ->
      match acc,x with
      | None,None -> None
      | Some x, _ -> acc
      | None,Some _ -> x) None results in
    match result with
    | None -> process_events ef.Event_types.token
    | Some x -> return x
  in
  lwt result_rc = process_events "" in
  lwt blobs = X.VM.get_blobs ~rpc ~session_id ~self:vm_ref in
  lwt stdout_b = Blob.of_ref rpc session_id (List.assoc (Printf.sprintf "stdout%d" n) blobs) in
  lwt stderr_b = Blob.of_ref rpc session_id (List.assoc (Printf.sprintf "stderr%d" n) blobs) in
  lwt stdout = Blob.get_blob host_config session_id stdout_b in
  lwt stderr = Blob.get_blob host_config session_id stderr_b in
  return (int_of_string result_rc, stdout, stderr)
  
let add_rpm host_config session_id uuid rpm_filename =
  let rpc = Host.get_rpc host_config in
  let key = "rpm-blobs" in
  lwt vm_ref = X.VM.get_by_uuid rpc session_id uuid in
  lwt value = Utils.read_file rpm_filename in
  let blobname = Filename.basename rpm_filename in
  lwt blob = Blob.add_blob_with_content host_config rpc session_id vm_ref blobname value in
  lwt oc = X.VM.get_other_config rpc session_id vm_ref in
  let rpms = try Utils.split ',' (List.assoc key oc) with _ -> [] in
  let new_rpms = String.concat "," (blob.Blob.u::rpms) in
  lwt () = X.VM.remove_from_other_config rpc session_id vm_ref key in
  X.VM.add_to_other_config rpc session_id vm_ref key new_rpms

let create_hash host vxs =
  let h = Hashtbl.create 10 in
  let l = [    "host",host.host;
	       "username",host.username;
	       "password",host.password;
	       "vm_uuid",vxs.vm_uuid;
	       "vxs_root_password",vxs.vxs_root_password;
	       "post_install_uuid",vxs.post_install.Blob.u;
	       "initscript_uuid",vxs.initscript.Blob.u;
	       "veryfirstboot_uuid",vxs.veryfirstboot.Blob.u;
	       "firstboot_uuid",vxs.firstboot.Blob.u;
	       "id_dsa_uuid",vxs.id_dsa.Blob.u;
	       "answerfile_uuid",vxs.answerfile.Blob.u;
	       "vsed_uuid",vxs.vsed.Blob.u;
	  ] in
  let extra = match vxs.ty with
    | Pxe branch -> 
      [ "branch",branch;
	"sourcetype","url" ]
    | Mainiso isoname ->
      [ "branch","";
	"sourcetype","local"] 
    | Custom ->
      [ "branch", "";
	"sourcetype", "" ]
  in
  List.iter (fun (x,y) -> Hashtbl.add h x (Tstr y)) (l @ extra);
  h
      
class string_loader =
object
  method check ~(template_name : string) ~(load_time : float) =
    CamlTemplate.Cache.TemplateUnchanged
      
  method load ~(template_name : string) =
    template_name
end

let loader = new string_loader

let cache = CamlTemplate.Cache.create ~loader ()

let get template host vxs =
  let h = create_hash host vxs in
  let tmpl = CamlTemplate.Cache.get_template cache template in
  let buf = Buffer.create 256 in
  CamlTemplate.merge tmpl h buf;
  Buffer.contents buf

let get_pxe_config = get Template.pxe_config_tmpl
let get_firstboot = get Template.firstboot_tmpl
let get_initscript = get Template.initscript_tmpl
let get_post_install = get Template.post_install_tmpl
let get_answerfile = get Template.answerfile_tmpl
let get_veryfirstboot = get Template.veryfirstboot_tmpl
let get_linux_cmdline = get Template.linux_cmdline_tmpl

let meg = Int64.mul 1024L 1024L
let gig = Int64.mul 1024L meg
let g2 = Int64.mul gig 2L
let g40 = Int64.mul gig 40L
let m4 = Int64.mul meg 4L

let exn_to_string = function
  | Api_errors.Server_error(code, params) ->
      Printf.sprintf "%s %s" code (String.concat " " params)
  | e -> Printexc.to_string e

type vxs_template = {
  vxs_r : string;
  vxs_name : string;
  vxs_uuid : string;
  vxs_install_time : string;
  vxs_ty : installty;
} with rpc

type vxs_templates = vxs_template list with rpc

let with_rpc_and_session host f =
    let uri = Printf.sprintf "http://%s/" host.host in
    let rpc = X.make uri in
    lwt session_id = X.Session.login_with_password rpc host.username host.password "1.0" in
    Lwt.finalize (fun () -> f ~rpc ~session_id) (fun () -> X.Session.logout ~rpc ~session_id)    

let wait rpc session_id classes pred =
  let rec inner token =
    lwt events = X.Event.from ~rpc ~session_id ~classes ~token ~timeout:1.0 in
    let ef = Event_types.event_from_of_rpc events in 
    let finished = List.exists (fun ev -> 
      pred (Event_helper.record_of_event ev)) ef.Event_types.events 
    in
    if not finished 
    then inner ef.Event_types.token
    else return ()
  in inner ""

let update_vxs_template_cache ~rpc ~session_id =
  lwt vms = X.VM.get_all_records ~rpc ~session_id in
  let vxs_templates = List.filter (fun (ref,_rec) -> List.mem_assoc "vxs_template" _rec.API.vM_other_config && _rec.API.vM_is_a_template) vms in
  let vxs_templates = List.map (fun (ref,_rec) ->
    let ty =  List.assoc "vxs_ty" _rec.API.vM_other_config in
    { vxs_r = ref;
      vxs_name = _rec.API.vM_name_label;
      vxs_uuid = _rec.API.vM_uuid;
      vxs_ty = installty_of_rpc (Jsonrpc.of_string (List.assoc "vxs_ty" _rec.API.vM_other_config));
      vxs_install_time = List.assoc "vxs_install_time" _rec.API.vM_other_config;
    }
  ) vxs_templates in
  lwt [p] = X.Pool.get_all ~rpc ~session_id in
  lwt () = X.Pool.remove_from_other_config ~rpc ~session_id ~self:p ~key:"vxs_template_cache" in
  lwt () = X.Pool.add_to_other_config ~rpc ~session_id ~self:p ~key:"vxs_template_cache" ~value:(Jsonrpc.to_string (rpc_of_vxs_templates vxs_templates)) in
  Lwt.return ()

let add_rpms host uuid rpms =
  with_rpc_and_session host (fun ~rpc ~session_id -> 
    let key = "rpm-blobs" in
    lwt vm_ref = X.VM.get_by_uuid rpc session_id uuid in
    let add_rpm file = 
      lwt value = Utils.read_file file in
      let blobname = Filename.basename file in
      lwt blob = Blob.add_blob_with_content host rpc session_id vm_ref blobname value in
      Lwt.return blob in
    lwt blobs = Lwt_list.map_s (fun rpm -> add_rpm rpm) rpms in
    lwt oc = X.VM.get_other_config rpc session_id vm_ref in
    let old_rpms = try Utils.split ',' (List.assoc key oc) with _ -> [] in
    let new_rpms = List.fold_left (fun acc blob -> blob.Blob.u :: acc) old_rpms blobs in   
    let new_rpms = String.concat "," new_rpms in
    let ty = installty_of_rpc (Jsonrpc.of_string (List.assoc "vxs_ty" oc)) in 
    lwt () = if ty <> Custom then begin
      lwt () = X.VM.remove_from_other_config rpc session_id vm_ref "vxs_ty" in
      lwt () = X.VM.add_to_other_config rpc session_id vm_ref "vxs_ty" (string_of_installty Custom) in
      lwt () = update_vxs_template_cache ~rpc ~session_id in
      Lwt.return ()
    end else Lwt.return () in
    lwt () = X.VM.remove_from_other_config rpc session_id vm_ref key in
    X.VM.add_to_other_config rpc session_id vm_ref key new_rpms)

let check_pxe_dir () =
  try_lwt 
    Lwt_unix.stat pxedir >> return ()
  with _ ->
    fail (Failure "No PXE dir")

let get_xenserver_templates ~rpc ~session_id =
  lwt p = X.Pool.get_all ~rpc ~session_id >|= List.hd in
  lwt oc = X.Pool.get_other_config ~rpc ~session_id ~self:p in
  let result = 
    try 
      let s = List.assoc "vxs_template_cache" oc in
      vxs_templates_of_rpc (Jsonrpc.of_string s)
    with _ ->
      [] 
  in
  Lwt.return result

let get_xenserver_templates_main host =
  with_rpc_and_session host get_xenserver_templates

let is_vxs_template rpc session_id template_ref =
  lwt oc = X.VM.get_other_config ~rpc ~session_id ~self:template_ref in
  lwt () = if not (List.mem_assoc "vxs_template" oc) then Lwt.fail (Failure "not a VXS template") else Lwt.return () in
  lwt is_t = X.VM.get_is_a_template ~rpc ~session_id ~self:template_ref in
  if not is_t then Lwt.fail (Failure "Not a template") else Lwt.return ()

let template_uninstall rpc session_id t_ref =
  lwt vbds = X.VM.get_VBDs ~rpc ~session_id ~self:t_ref in
  lwt vdis = Lwt_list.fold_left_s 
    (fun acc vbd -> try
			(* We only destroy VDIs where VBD.other_config contains 'owner' *)
		      lwt other_config = X.VBD.get_other_config rpc session_id vbd in
		      lwt vdi = X.VBD.get_VDI rpc session_id vbd in
			(* Double-check the VDI actually exists *)
		      ignore(X.VDI.get_uuid rpc session_id vdi);
		      if List.mem_assoc "owner" other_config
		      then Lwt.return (vdi :: acc) else Lwt.return acc
      with _ -> Lwt.return acc) [] vbds in
  lwt () = X.VM.destroy rpc session_id t_ref in
  lwt () = Lwt_list.iter_s (fun vdi -> X.VDI.destroy rpc session_id vdi) vdis in
  Lwt.return ()
    
let template_destroy host template_uuid =
  with_rpc_and_session host (fun ~rpc ~session_id ->
    lwt vm = X.VM.get_by_uuid ~rpc ~session_id ~uuid:template_uuid in
    lwt () = is_vxs_template rpc session_id vm in
    lwt () = template_uninstall rpc session_id vm in
    lwt () = update_vxs_template_cache ~rpc ~session_id in
    Lwt.return ())
  
let template_clone host template_uuid new_name =
  with_rpc_and_session host (fun ~rpc ~session_id ->
    lwt vm = X.VM.get_by_uuid ~rpc ~session_id ~uuid:template_uuid in
    lwt () = is_vxs_template rpc session_id vm in
    lwt new_vm = X.VM.clone ~rpc ~session_id ~vm ~new_name in
    lwt () = update_vxs_template_cache ~rpc ~session_id in
    lwt uuid = X.VM.get_uuid ~rpc ~session_id ~self:new_vm in
    Lwt.return (new_vm,uuid))
  
let install_from_template rpc session_id template_ref new_name =
  let vm = template_ref in
  lwt () = is_vxs_template rpc session_id template_ref in
  lwt new_vm = X.VM.clone ~rpc ~session_id ~vm ~new_name in
  lwt () = X.VM.provision ~rpc ~session_id ~vm:new_vm in
  lwt () = X.VM.remove_from_other_config ~rpc ~session_id ~self:new_vm ~key:"vxs_template" in
  lwt () = X.VM.add_to_other_config ~rpc ~session_id ~self:new_vm ~key:"vxs" ~value:"true" in
  lwt uuid = X.VM.get_uuid ~rpc ~session_id ~self:new_vm in
  Lwt.return (new_vm,uuid)

let get_by_uuid_or_by_name rpc session_id id =
  lwt vm = 
    try_lwt 
      lwt vm_ref = X.VM.get_by_uuid ~rpc ~session_id ~uuid:id in
      Lwt.return (vm_ref,id)
    with _ -> 
      lwt vms = X.VM.get_by_name_label ~rpc ~session_id ~label:id in
      let hd = List.hd vms in
      lwt uuid = X.VM.get_uuid ~rpc ~session_id ~self:hd in
      Lwt.return (hd,uuid)
  in
  Lwt.return vm

let install_vxs host template new_name =
  with_rpc_and_session host (fun ~rpc ~session_id -> 
    lwt (vm,uuid) = get_by_uuid_or_by_name rpc session_id template in
    install_from_template rpc session_id vm new_name)
    
let create_xenserver_template host ty =
  lwt () = match ty with | Pxe _ -> check_pxe_dir () | _ -> Lwt.return () in
  with_rpc_and_session host (fun ~rpc ~session_id -> 
    lwt templates = X.VM.get_all_records_where ~rpc ~session_id ~expr:"field \"name__label\" = \"Other install media\"" in
    let (template,_) = List.hd templates in
    Printf.printf "Found template ref: %s\n" template;
    lwt vm = X.VM.clone ~rpc ~session_id ~vm:template ~new_name:"xenserver-unknown" in
    lwt vm_uuid = X.VM.get_uuid ~rpc ~session_id ~self:vm in
    lwt () = X.VM.provision ~rpc ~session_id ~vm in
    lwt () = X.VM.set_memory_limits ~rpc ~session_id ~self:vm ~static_min:g2 ~static_max:g2 ~dynamic_min:g2 ~dynamic_max:g2 in
    
    lwt nets = X.Network.get_all_records_where ~rpc ~session_id ~expr:"field \"bridge\" = \"xenbr0\"" in
    let (network,_) = List.hd nets in
    lwt vif = X.VIF.create ~rpc ~session_id ~device:"0" ~network ~vM:vm ~mAC:"" ~mTU:1500L ~other_config:[] ~qos_algorithm_type:"" ~qos_algorithm_params:[] ~locking_mode:`unlocked ~ipv4_allowed:[] ~ipv6_allowed:[] in
    lwt pools = X.Pool.get_all ~rpc ~session_id in
    let pool = List.hd pools in
    lwt master = X.Pool.get_master ~rpc ~session_id  ~self:pool in
    lwt servertime = X.Host.get_servertime ~rpc ~session_id ~host:master in
    lwt default_sr = X.Pool.get_default_SR ~rpc ~session_id ~self:pool in
    lwt vdi = X.VDI.create ~rpc ~session_id ~sR:default_sr ~name_label:"Root disk" ~name_description:"" ~virtual_size:g40 ~_type:`user ~sharable:false ~read_only:false ~other_config:[] ~xenstore_data:[] ~sm_config:[] ~tags:[] in 
    lwt vbd = X.VBD.create ~rpc ~session_id ~vDI:vdi ~vM:vm ~userdevice:"0" ~bootable:true ~mode:`RW ~_type:`Disk ~unpluggable:false ~empty:false ~other_config:["owner",""] ~qos_algorithm_type:"" ~qos_algorithm_params:[] in
    ignore(vbd);
    lwt answerfile = Blob.add_blob rpc session_id vm "answerfile" in
    lwt post_install = Blob.add_blob rpc session_id vm "post_install" in
    lwt initscript = Blob.add_blob rpc session_id vm "initscript" in
    lwt veryfirstboot = Blob.add_blob rpc session_id vm "veryfirstboot" in
    lwt firstboot = Blob.add_blob rpc session_id vm "firstboot" in
    lwt id_dsa = Blob.add_blob rpc session_id vm "id_dsa" in
    lwt vsed = Blob.add_blob rpc session_id vm "vsed" in

    let vxs_template_config = {
      ty;
      vm_uuid;
      vxs_root_password = host.password;
      post_install;
      initscript;
      veryfirstboot;
      firstboot;
      id_dsa;
      answerfile;
      vsed;
    } in

    let blobs = [
      answerfile, get_answerfile;
      post_install, get_post_install;
      initscript, get_initscript;
      veryfirstboot, get_veryfirstboot;
      firstboot, get_firstboot;
    ] in
    
    lwt () = Lwt_list.iter_s (fun (x,y) -> 
      Blob.put_blob host session_id x (y host vxs_template_config)) blobs in
    
    lwt () = Blob.put_blob host session_id vsed Template.vsed_string in
    
    let pub_name = (Filename.concat (Sys.getenv "HOME") ".ssh/id_rsa.pub") in
    lwt exist = try_lwt 
		  lwt _ = Lwt_unix.stat pub_name in
		  Lwt.return true
      with _ -> Lwt.return false  in 
    lwt () = if exist then begin
      lwt id_dsa_string = Utils.read_file pub_name  in
      Blob.put_blob host session_id id_dsa id_dsa_string
    end else Lwt.return () in   
    
    let linux_cmdline = get_linux_cmdline host vxs_template_config in
    
    let pxe_path = Printf.sprintf "%s/%s" pxedir vm_uuid in
    let pxe_config = get_pxe_config host vxs_template_config in
    
    lwt () = begin match vxs_template_config.ty with
      | Pxe branch ->
	lwt fd = Lwt_unix.openfile pxe_path [Lwt_unix.O_WRONLY; Lwt_unix.O_CREAT] 0o666 in
        let c = Lwt_io.(of_fd output fd) in
	
	lwt () = Lwt_io.write c pxe_config in
        lwt () = Lwt_io.close c in
	
        lwt () = X.VM.remove_from_HVM_boot_params ~rpc ~session_id ~self:vm ~key:"order" in
        lwt () = X.VM.add_to_HVM_boot_params ~rpc ~session_id ~self:vm ~key:"order" ~value:"ncd" in
	
        Lwt.return () 
      | Mainiso isoname ->
	lwt isos = X.VDI.get_by_name_label ~rpc ~session_id ~label:isoname in
        let iso = List.hd isos in
        lwt vbd = X.VBD.create ~rpc ~session_id ~vDI:iso ~vM:vm ~userdevice:"3" ~bootable:true ~mode:`RO ~_type:`CD ~unpluggable:true ~empty:false ~other_config:[] ~qos_algorithm_type:"" ~qos_algorithm_params:[] in
        lwt vdi2 = X.VDI.create ~rpc ~session_id ~sR:default_sr ~name_label:"Autoinstall disk" ~name_description:"" ~virtual_size:m4 ~_type:`user ~sharable:false ~read_only:false ~other_config:[] ~xenstore_data:[] ~sm_config:[] ~tags:[] in
        lwt vbd = X.VBD.create ~rpc ~session_id ~vDI:vdi2 ~vM:vm ~userdevice:"1" ~bootable:false ~mode:`RW ~_type:`Disk ~unpluggable:false ~empty:false ~other_config:["owner",""] ~qos_algorithm_type:"" ~qos_algorithm_params:[] in
        let fname = "/tmp/autoinstalldisk" in
        lwt () = Utils.create_vfat_disk fname "autoinstall" in
        lwt () = Utils.copy_to_vfat fname "cmdline" linux_cmdline in
        lwt contents = Utils.read_file fname  in
        lwt () = Utils.put_disk host session_id vdi2 contents in
        Lwt.return ()
    end in
    
    lwt () = X.VM.start ~rpc ~session_id ~vm ~start_paused:false ~force:false in
    lwt () = X.VM.remove_from_HVM_boot_params ~rpc ~session_id ~self:vm ~key:"order" in
    lwt () = X.VM.add_to_HVM_boot_params ~rpc ~session_id ~self:vm ~key:"order" ~value:"cd" in
    lwt () = X.VM.add_to_other_config ~rpc ~session_id ~self:vm ~key:"vxs_install_time" ~value:servertime in
    lwt () = X.VM.add_to_other_config ~rpc ~session_id ~self:vm ~key:"vxs_ty" ~value:(string_of_installty ty) in 
    
    lwt () = wait rpc session_id [Printf.sprintf "vm/%s" vm] (function 
      | Event_helper.VM (_,Some r) ->
	r.API.vM_power_state = `Halted
      | _ -> false) in
    
    lwt oc = X.VM.get_other_config ~rpc ~session_id ~self:vm in
    if List.mem_assoc "vxs_template" oc 
    then begin
      lwt () = X.VM.set_is_a_template ~rpc ~session_id ~self:vm ~value:true in
      lwt () = update_vxs_template_cache ~rpc ~session_id in
      return vm_uuid
    end else begin
      (* Leaking disk if we're using mainiso install type *)
      lwt () = X.VDI.destroy ~rpc ~session_id ~self:vdi in
      lwt () = X.VM.destroy ~rpc ~session_id ~self:vm in
      Lwt.fail (Failure "VM failed to install correctly")
    end)
    
    
exception Unknown_template of string

let rec l_init = function
  | 0 -> []
  | n -> n :: (l_init (n-1))

let create_pool host template pool_name nhosts nfs_server nfs_path =
  with_rpc_and_session host (fun ~rpc ~session_id -> 
    let starttime = Unix.gettimeofday () in
    lwt templates = get_xenserver_templates rpc session_id in
    lwt t = try Lwt.return (List.find (fun x -> x.vxs_uuid = template) templates) with _ -> fail (Unknown_template template) in
    lwt vms = Lwt_list.map_p (fun n -> 
      lwt (vm,u) = install_from_template rpc session_id t.vxs_r (Printf.sprintf "%s%d" pool_name n) in
      lwt () = X.VM.start ~rpc ~session_id ~vm ~start_paused:false ~force:false in
      Lwt.return (vm,u))
      (l_init nhosts) in
    let endtime = Unix.gettimeofday () in
    Printf.printf "%d host%s created (time taken: %f seconds)\n%!" nhosts (if nhosts>1 then "s" else "") (endtime -. starttime);
    let master = List.hd vms in
    let slaves = List.tl vms in
    let wait_for_ip (vm,_) = 
      lwt () = wait rpc session_id [Printf.sprintf "vm/%s" vm] (function
      | Event_helper.VM (_,Some r) ->
        List.mem_assoc "vxs_ip" r.API.vM_other_config
      | _ -> false) in
      lwt oc = X.VM.get_other_config ~rpc ~session_id ~self:vm in
      let ip = List.assoc "vxs_ip" oc in
      Lwt.return ip
    in
    let starttime = Unix.gettimeofday () in
    lwt ips = Lwt_list.map_s wait_for_ip vms in
    let endtime = Unix.gettimeofday () in
    let master_ip = List.hd ips in
    let master_uuid = snd master in
    lwt () = match nfs_server,nfs_path with
      | Some s,Some p -> 
	lwt n = submit_rpc host session_id master_uuid 
	  (Printf.sprintf "#!/bin/bash\nxe sr-create type=nfs device-config:server=%s device-config:serverpath=%s shared=true name-label=nfs\n" s p) in
	lwt response = get_response host session_id master_uuid n in
	Printf.printf "NFS server setup on master\n";
	Lwt.return ()
      | _,_ -> Lwt.return () in
    Printf.printf "All hosts have reported their IPs (time taken: %f seconds). Master IP=%s Joining pool\n%!" (endtime -. starttime) master_ip;
    lwt rpcs = Lwt_list.map_s (fun (r,u) -> lwt n = submit_rpc host session_id u (Printf.sprintf "#!/bin/bash\nxe pool-join master-address=%s master-username=root master-password=xenroot\n" master_ip) in Lwt.return (u,n)) slaves in
    lwt responses = Lwt_list.map_s (fun (u,n) -> get_response host session_id u n) rpcs in
    let endtime2 = Unix.gettimeofday () in
    Printf.printf "All done. Time for pool join: %f seconds\n%!" (endtime2 -. endtime);
    List.iter (fun (rc,out,err) -> Printf.printf "rc: %d\nout: %s\nerr: %s\n%!" rc out err) responses;
    Lwt.return ())

let exec_rpc host id script nowait =
  with_rpc_and_session host (fun ~rpc ~session_id -> 
    lwt script = Utils.read_file script in
    lwt (vm_ref,uuid) = get_by_uuid_or_by_name rpc session_id id in
    lwt n = submit_rpc host session_id uuid script in
    lwt () = if not nowait then begin
      lwt (rc,out,err) = get_response host session_id uuid n in
      Printf.printf "rc: %d\nout: %s\nerr: %s\n%!" rc out err;
      Lwt.return ()
    end else Lwt.return () in
    Lwt.return ()
  )

let get_vm_ip host id = 
  with_rpc_and_session host (fun ~rpc ~session_id ->
    lwt (vm_ref,uuid) = get_by_uuid_or_by_name rpc session_id id in
    lwt oc = X.VM.get_other_config ~rpc ~session_id ~self:vm_ref in
    let ip = List.assoc "vxs_ip" oc in
    Lwt.return ip)
