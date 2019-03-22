MODULE statequil_atoms

 use atmos_type, only : atmos
 use atom_type
 use spectrum_type, only : NLTEspec
 use constant
 use opacity, only : cont_wlam
 use math, only : locate
 use utils, only : GaussSlv

 IMPLICIT NONE

 CONTAINS
 
 SUBROUTINE initGamma(icell) !icell temporary
 ! ------------------------------------------------------ !
  !for each active atom, allocate and init Gamma matrix
  !deallocated in freeAtom()
  ! Collision matrix has to be allocated
  ! if already allocated, simply set Gamma to its new icell
  ! value.
 ! ------------------------------------------------------ !
  integer :: nact, Nlevel, i, j, ij
  integer, intent(in) :: icell
  type (AtomType), pointer :: atom
  
  do nact = 1, atmos%Nactiveatoms
   atom => atmos%ActiveAtoms(nact)%ptr_atom
   Nlevel = atom%Nlevel
   ij = 0
   if (.not.allocated(atom%Gamma)) allocate(atom%Gamma(Nlevel, Nlevel))
   do i=1, Nlevel
    do j=1,Nlevel
      ij = ij + 1
      atom%Gamma(i,j) = atom%Ckij(icell,ij)!atom%C(ij) 
    end do
   end do
   NULLIFY(atom)
  end do
 
 RETURN
 END SUBROUTINE initGamma

 SUBROUTINE initCrossCoupling(id)
  integer, intent(in) :: id
  integer :: nact
  
  do nact=1,atmos%Nactiveatoms
   atmos%ActiveAtoms(nact)%ptr_atom%Uji_down(:,:,id) = 0d0!0 if j<i
   atmos%ActiveAtoms(nact)%ptr_atom%chi_up(:,:,id) = 0d0
   atmos%ActiveAtoms(nact)%ptr_atom%chi_down(:,:,id) = 0d0
   
   !init eta at the same time
   atmos%ActiveAtoms(nact)%ptr_atom%eta(:,id) = 0d0
  end do
 
 RETURN
 END SUBROUTINE initCrossCoupling
 
 SUBROUTINE fillCrossCoupling_terms(id, icell)
 
  !previously allocated for this thread
  integer, intent(in) :: id, icell
  integer nact, i, j, kl
  type (AtomType), pointer :: atom
  type (AtomicContinuum) :: cont
  type (AtomicLine) :: line
  double precision, dimension(NLTEspec%Nwaves) :: twohnu3_c2, chicc
  
  do nact=1,atmos%Nactiveatoms
   atom => atmos%ActiveAtoms(nact)%ptr_atom
   !init for that atom for this (id,icell) point
   atom%Uji_down(:,:,id) = 0d0
   atom%chi_down(:,:,id) = 0d0; atom%chi_up(:,:,id) = 0d0

   do kl=1,atom%Ncont
    cont = atom%continua(kl)
    twohnu3_c2 = 2d0 * HPLANCK * CLIGHT / (NM_TO_M * NLTEspec%lambda)**(3d0)
    i = cont%i; j = cont%j
    chicc = cont%Vij(:,id) * (atom%n(i,icell) - cont%gij(:,id)*atom%n(j,icell))
    
    atom%Uji_down(j,:,id) = atom%Uji_down(j,:,id) + twohnu3_c2*cont%gij(:,id)*cont%Vij(:,id)
    atom%chi_up(i,:,id) = atom%chi_up(i,:,id) + chicc
    atom%chi_down(j,:,id) = atom%chi_down(j,:,id) + chicc
   end do

   do kl=1,atom%Nline
    line = atom%lines(kl)
    twohnu3_c2 = line%Aji/line%Bji
    i = line%i; j = line%j
    chicc = line%Vij(:,id) * (atom%n(i,icell) - line%gij(:,id)*atom%n(j,icell))

    atom%Uji_down(j,:,id) = atom%Uji_down(j,:,id) + twohnu3_c2*line%gij(:,id)*line%Vij(:,id)
    atom%chi_up(i,:,id) = atom%chi_up(i,:,id) + chicc
    atom%chi_down(j,:,id) = atom%chi_down(j,:,id) + chicc
   end do   
   NULLIFY(atom)
  end do
 RETURN
 END SUBROUTINE fillCrossCoupling_terms
 
 SUBROUTINE fillGamma(id,icell,iray,n_rayons, switch_to_ALI)
 !------------------------------------------------- !
  ! for all atoms, performs wavelength
  ! and angle integration of rate matrix
  ! The angle integration is done by nray calls of 
  ! this routine
  ! What are the integration weights ??? 
  ! I cannot use monte-carlo for wavelength integration
  ! because lambda is fixed for each line.
  ! or generate a grid and interpolate the value on this
  ! random grid ?
 !------------------------------------------------- !
  integer, intent(in) :: id, icell, iray, n_rayons
  logical, intent(in), optional :: switch_to_ALI
  integer :: nact, nc, kr, switch,i, j, Nblue, Nred, jp, krr
  type (AtomType), pointer :: atom
  double precision, dimension(:), allocatable :: Ieff
  double precision, dimension(NLTEspec%Nwaves) :: twohnu3_c2
  double precision :: norm = 0d0, hc_4PI, diag
    
  !FLAG to change from MALI to ALI
  if (present(switch_to_ALI)) then
   if (switch_to_ALI) switch = 0
  else
   switch = 1
  end if
  
  allocate(Ieff(NLTEspec%Nwaves)); Ieff=0d0
  hc_4PI = HPLANCK * CLIGHT / 4d0 / PI
  
  do nact=1,atmos%Nactiveatoms !loop over each active atoms
   atom => atmos%ActiveAtoms(nact)%ptr_atom
   Ieff(:) = NLTEspec%I(:,iray,id) - NLTEspec%Psi(:,iray,id) * atom%eta(:,id)!at this iray, id
   
   !loop over transitions, b-f and b-b for these atoms
   !To do; define a transition_type with either cont or line
   do kr=1,atom%Ncont
    norm = sum(cont_wlam(atom%continua(kr))) / n_rayons
    i = atom%continua(kr)%i; j = atom%continua(kr)%j
    Nblue = atom%continua(kr)%Nblue; Nred = atom%continua(kr)%Nred 
    twohnu3_c2 = 2d0 * HPLANCK * CLIGHT / (NLTEspec%lambda*NM_TO_M)**3.
    
    !Ieff (Uij = 0 'cause i<j)
    atom%Gamma(i,j) = atom%Gamma(i,j) + hc_4PI * sum(Ieff(Nblue:Nred)*cont_wlam(atom%continua(kr))) / norm
    !Uji + Vji*Ieff
    !Uji and Vji express with Vij
    atom%Gamma(j,i) = atom%Gamma(j,i) +  hc_4PI * sum((Ieff(Nblue:Nred)+twohnu3_c2(Nblue:Nred))*&
    	atom%continua(kr)%gij(Nblue:Nred,id)*cont_wlam(atom%continua(kr))) / norm
    	
    ! cross-coupling terms
     atom%Gamma(i,j) = atom%Gamma(i,j) -sum((atom%chi_up(i,:,id)*NLTEspec%Psi(:, iray, id)*&
     	atom%Uji_down(j,:,id))*cont_wlam(atom%continua(kr))) / norm
     ! check if i is an upper level of another transition
     do krr=1,atom%Ncont
      jp = atom%continua(krr)%j
      if (jp==i) then !i upper level of this transition
       atom%Gamma(j,i) = atom%Gamma(j,i) + sum((atom%chi_down(j,:,id)*nLTEspec%Psi(:, iray, id)*&
       	atom%Uji_down(i,:,id))*cont_wlam(atom%continua(kr))) / norm
      end if 
     end do
    !
   end do
   do kr=1,atom%Nline
    i = atom%lines(kr)%i; j = atom%lines(kr)%j
    Nblue = atom%lines(kr)%Nblue; Nred = atom%lines(kr)%Nred 
    twohnu3_c2 = atom%lines(kr)%Aji / atom%lines(kr)%Bji 
    
    !Ieff (Uij = 0 'cause i<j)
    atom%Gamma(i,j) = atom%Gamma(i,j) + sum(Ieff(Nblue:Nred)*atom%lines(kr)%wlam(Nblue:Nred)) / n_rayons
    !Uji + Vji*Ieff
    !Uji and Vji express with Vij
    atom%Gamma(j,i) = atom%Gamma(j,i) +  sum((Ieff(Nblue:Nred)+twohnu3_c2(Nblue:Nred))*&
    	atom%lines(kr)%gij(Nblue:Nred,id)*atom%lines(kr)%wlam(Nblue:Nred)) / n_rayons
    	
    ! cross-coupling terms
     atom%Gamma(i,j) = atom%Gamma(i,j) -sum(atom%chi_up(i,:,id)*NLTEspec%Psi(:, iray, id)*&
     	atom%Uji_down(j,:,id)) / n_rayons
     ! check if i is an upper level of another transition
     do krr=1,atom%Nline
      jp = atom%lines(krr)%j
      if (jp==i) then !i upper level of this transition
       atom%Gamma(j,i) = atom%Gamma(j,i) + sum(atom%chi_down(j,:,id)*nLTEspec%Psi(:, iray, id)*&
       	atom%Uji_down(i,:,id)) / n_rayons
      end if 
     end do
    ! 
   end do
   
   !remove diagonal here, delat(l',l)
   do i=1,atom%Nlevel
    atom%Gamma(i,i) = 0d0 !because i that case Gamma_l"l = Cii - Cii = 0d0
    diag = 0d0
    do j=1,atom%Nlevel
     diag = diag + atom%Gamma(i,j) 
    end do
    atom%Gamma(i,i) = atom%Gamma(i,i) - diag
   end do
   
   NULLIFY(atom)
  end do !loop over atoms
  deallocate(Ieff)
 RETURN
 END SUBROUTINE fillGamma
 
 SUBROUTINE SEE_atom(id, icell, atom)
  integer, intent(in) :: icell, id
  type(AtomType), intent(inout) :: atom
  integer :: j, i, imaxpop
  double precision, dimension(atom%Nlevel) :: nold
  
  do i=1,atom%Nlevel
  write(*,*) (atom%Gamma(i,j), j=1,atom%Nlevel)
  end do
  
  nold(:) = atom%n(:,icell)
  !search the row with maximum population and remove it
  imaxpop = locate(nold, maxval(nold))
  nold(imaxpop) = 1d0
  
  atom%Gamma(imaxpop,:) = 1d0
  CALL GaussSlv(atom%Gamma, nold,atom%Nlevel)
  atom%n(:,icell) = nold(:)

 RETURN
 END SUBROUTINE SEE_atom
 
 SUBROUTINE updatePopulations(id, icell)
  integer, intent(in) :: id, icell
  type(AtomType), pointer :: atom
  integer :: nat
  
  do nat=1,atmos%NactiveAtoms
   atom => atmos%ActiveAtoms(nat)%ptr_atom
   CALL SEE_atom(id, icell, atom)
   !Ng's acceleration
   !print Ng acceleration pops.
   NULLIFY(atom)
  end do
 
 RETURN
 END SUBROUTINE updatePopulations
 
 SUBROUTINE initRadiativeRates(atom)
 ! ---------------------------------------- !
  ! For each transition of AtomType atom
  ! set radiative rates to 0
 ! ---------------------------------------- !
  integer :: kc, kr
  type (AtomType), intent(inout) :: atom
  
   do kc=1,atom%Ncont
    atom%continua(kc)%Rij = 0d0
    atom%continua(kc)%Rji = 0d0
   end do
   do kr=1,atom%Nline
    atom%lines(kr)%Rij = 0d0
    atom%lines(kr)%Rji = 0d0
   end do 
   
 RETURN
 END SUBROUTINE initRadiativeRates
 
 SUBROUTINE allocNetCoolingRates(atom)
 ! ----------------------------------------------- !
  ! For each transition of AtomType atom
  ! allocate cooling rates.
  ! It avoids to store 2 x Ntransitons * Nspace
  ! arrays of radiative rates.
  ! Instead Ntranstions * Nspace arrays of cooling
  ! rates
 ! ----------------------------------------------- !
  integer :: kc, kr
  type (AtomType), intent(inout) :: atom
   write(*,*) "Allocating net cooling rates..."
   write(*,*) "  -> continuum cooling rates not implemented yet"
!    do kc=1,atom%Ncont
!     allocate(atom%continua(kc)%CoolRates_ij(atmos%Nspace))
!     atom%continua(kc)%CoolRates_ij(:) = 0d0
!    end do
   do kr=1,atom%Nline
    allocate(atom%lines(kr)%CoolRates_ij(atmos%Nspace))
    atom%lines(kr)%CoolRates_ij(:) = 0d0
   end do 

 RETURN
 END SUBROUTINE allocNetCoolingRates
 
 SUBROUTINE addtoRadiativeRates()
 ! -------------------------------------------- !
  ! For each atoms and each transitions
  ! compute the radiative rates
  ! It is a integral over frequency and angles
  !
 ! -------------------------------------------- !
 
 
 RETURN
 END SUBROUTINE addtoRadiativeRates


END MODULE statequil_atoms
